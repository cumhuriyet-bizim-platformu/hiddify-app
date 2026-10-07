import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/connection/notifier/dead_tunnel_watcher.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';

const _timeout = 65535; // sing-box monitoring.TimeoutDelay

OutboundGroup _group(List<int> delays, {bool withSubGroups = true}) => OutboundGroup(
  tag: 'select',
  items: [
    // Balancer/selector items are groups: their own delay never decides "dead".
    if (withSubGroups) OutboundInfo(tag: 'lowest', isGroup: true, urlTestDelay: 120),
    for (var i = 0; i < delays.length; i++) OutboundInfo(tag: 'p$i', urlTestDelay: delays[i]),
  ],
);

class _Clock {
  DateTime t = DateTime(2026, 10, 7, 12);
  DateTime now() => t;
  void advance(Duration d) => t = t.add(d);
}

class _Harness {
  _Harness() {
    watcher = DeadTunnelWatcher(
      watchGroup: () {
        subscriptions++;
        return groups.stream;
      },
      onAllDead: () async => calls++,
      now: clock.now,
    );
  }

  final clock = _Clock();
  final groups = StreamController<OutboundGroup?>.broadcast();
  late final DeadTunnelWatcher watcher;
  int calls = 0;
  int subscriptions = 0;

  Future<void> emit(OutboundGroup? g) async {
    groups.add(g);
    await pumpEventQueue();
  }
}

void main() {
  group('allOutboundsFailed', () {
    test('every leaf outbound timed out → dead', () {
      expect(DeadTunnelWatcher.allOutboundsFailed(_group([_timeout, _timeout])), isTrue);
    });
    test('one healthy outbound → not dead', () {
      expect(DeadTunnelWatcher.allOutboundsFailed(_group([_timeout, 230])), isFalse);
    });
    test('an untested outbound (delay 0) is not a failure', () {
      expect(DeadTunnelWatcher.allOutboundsFailed(_group([_timeout, 0])), isFalse);
    });
    test('no group / no leaf outbounds → not dead', () {
      expect(DeadTunnelWatcher.allOutboundsFailed(null), isFalse);
      expect(DeadTunnelWatcher.allOutboundsFailed(_group([])), isFalse);
    });
  });

  group('DeadTunnelWatcher', () {
    test('every outbound fails after the grace window → one onAllDead', () async {
      final h = _Harness();
      h.watcher.onConnected();
      h.clock.advance(const Duration(seconds: 61));
      await h.emit(_group([_timeout, _timeout]));
      expect(h.calls, 1);
      await h.watcher.dispose();
    });

    test('one healthy outbound → nothing happens', () async {
      final h = _Harness();
      h.watcher.onConnected();
      h.clock.advance(const Duration(minutes: 2));
      await h.emit(_group([_timeout, 150]));
      expect(h.calls, 0);
      await h.watcher.dispose();
    });

    test('two all-dead events 2 minutes apart → one update; 6 minutes apart → two', () async {
      final h = _Harness();
      h.watcher.onConnected();
      h.clock.advance(const Duration(minutes: 1, seconds: 1));
      await h.emit(_group([_timeout]));
      h.clock.advance(const Duration(minutes: 2));
      await h.emit(_group([_timeout]));
      expect(h.calls, 1);

      h.clock.advance(const Duration(minutes: 4)); // 6 minutes after the first
      await h.emit(_group([_timeout]));
      expect(h.calls, 2);
      await h.watcher.dispose();
    });

    test('noRefreshDuringConnectGrace: all-dead within 60 s of connecting → nothing', () async {
      final h = _Harness();
      h.watcher.onConnected();
      h.clock.advance(const Duration(seconds: 5));
      await h.emit(_group([_timeout, _timeout]));
      h.clock.advance(const Duration(seconds: 50));
      await h.emit(_group([_timeout, _timeout]));
      expect(h.calls, 0);
      await h.watcher.dispose();
    });

    test('noRefreshDuringConnectGrace: a reconnect restarts the grace window and the rate limit holds', () async {
      final h = _Harness();
      h.watcher.onConnected();
      h.clock.advance(const Duration(minutes: 2));
      await h.emit(_group([_timeout]));
      expect(h.calls, 1);

      // Network change / reconnect: every outbound briefly reports a failure.
      h.watcher.onDisconnected();
      h.clock.advance(const Duration(seconds: 3));
      h.watcher.onConnected();
      h.clock.advance(const Duration(seconds: 10));
      await h.emit(_group([_timeout]));
      expect(h.calls, 1, reason: 'inside the new grace window');

      h.clock.advance(const Duration(seconds: 60));
      await h.emit(_group([_timeout]));
      expect(h.calls, 1, reason: 'grace passed but the 5-minute rate limit still holds across reconnects');
      await h.watcher.dispose();
    });

    test('not connected → events are ignored and the stream is not watched', () async {
      final h = _Harness();
      h.clock.advance(const Duration(minutes: 10));
      await h.emit(_group([_timeout]));
      expect(h.calls, 0);
      expect(h.subscriptions, 0);

      h.watcher.onConnected();
      h.watcher.onDisconnected();
      h.clock.advance(const Duration(minutes: 10));
      await h.emit(_group([_timeout]));
      expect(h.calls, 0);
      await h.watcher.dispose();
    });

    test('a slow onAllDead never overlaps with itself', () async {
      final clock = _Clock();
      final groups = StreamController<OutboundGroup?>.broadcast();
      final gate = Completer<void>();
      var calls = 0;
      final w = DeadTunnelWatcher(
        watchGroup: () => groups.stream,
        onAllDead: () async {
          calls++;
          await gate.future;
        },
        now: clock.now,
      );
      w.onConnected();
      clock.advance(const Duration(minutes: 2));
      groups.add(_group([_timeout]));
      await pumpEventQueue();
      clock.advance(const Duration(minutes: 6));
      groups.add(_group([_timeout]));
      await pumpEventQueue();
      expect(calls, 1);
      gate.complete();
      await w.dispose();
    });
  });

  group('refreshAndReconnectIfChanged', () {
    test('every outbound failed → one update; unchanged content → no reconnect', () async {
      var updates = 0;
      var reconnects = 0;
      final reconnected = await refreshAndReconnectIfChanged(
        readStoredConfig: () async => 'config-v1',
        forceUpdate: () async {
          updates++;
          return true;
        },
        reconnect: () async => reconnects++,
      );
      expect(updates, 1);
      expect(reconnects, 0);
      expect(reconnected, isFalse);
    });

    test('changed content → exactly one reconnect', () async {
      var stored = 'config-v1';
      var updates = 0;
      var reconnects = 0;
      final reconnected = await refreshAndReconnectIfChanged(
        readStoredConfig: () async => stored,
        forceUpdate: () async {
          updates++;
          stored = 'config-v2';
          return true;
        },
        reconnect: () async => reconnects++,
      );
      expect(updates, 1);
      expect(reconnects, 1);
      expect(reconnected, isTrue);
    });

    test('failed update → no reconnect', () async {
      var reconnects = 0;
      await refreshAndReconnectIfChanged(
        readStoredConfig: () async => 'config-v1',
        forceUpdate: () async => false,
        reconnect: () async => reconnects++,
      );
      expect(reconnects, 0);
    });
  });

  group('refreshAndReconnectIfChanged normalised comparison', () {
    String cfg({String ip = '1.2.3.4', String header = 'Linux', String sid = 'aa', bool extra = false}) => jsonEncode({
      'outbounds': [
        {
          'type': 'vless',
          'tag': 'x-$sid',
          'server': ip,
          'server_port': 443,
          'headers': {'sec-ch-ua-platform': header},
          'tls': {
            'reality': {'short_id': sid},
          },
        },
        if (extra) {'type': 'vless', 'tag': 'y', 'server': '5.6.7.8', 'server_port': 443},
      ],
    });

    Future<int> run(String before, String after) async {
      var stored = before;
      var reconnects = 0;
      await refreshAndReconnectIfChanged(
        readStoredConfig: () async => stored,
        forceUpdate: () async {
          stored = after;
          return true;
        },
        reconnect: () async => reconnects++,
      );
      return reconnects;
    }

    test('only header and short_id differ → no reconnect', () async {
      expect(await run(cfg(), cfg(header: 'Windows', sid: 'bb')), 0);
    });
    test('different server IP → reconnect', () async {
      expect(await run(cfg(), cfg(ip: '9.9.9.9')), 1);
    });
    test('added outbound → reconnect', () async {
      expect(await run(cfg(), cfg(extra: true)), 1);
    });
    test('unparsable content → raw comparison', () async {
      expect(await run('not json a', 'not json a'), 0);
      expect(await run('not json a', 'not json b'), 1);
    });
  });
}
