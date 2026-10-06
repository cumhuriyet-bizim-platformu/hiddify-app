import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

/// Derbent: fail closed. Only a known, data-backed Disconnected status may send the update check
/// direct. Connected, connecting, disconnecting, loading and error all mean proxy-only: an unknown
/// status must never leak a GitHub contact outside a tunnel that may be up.
bool updateCheckProxyOnly(AsyncValue<ConnectionStatus> status) => status.valueOrNull?.isDisconnected != true;
