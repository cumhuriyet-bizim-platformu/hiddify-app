#! /bin/bash
SED() { [[ "$OSTYPE" == "darwin"* ]] && sed -i '' "$@" || sed -i "$@"; }
echo "previous version was $(git describe --tags $(git rev-list --tags --max-count=1))"
echo "WARNING: This operation will creates version tag and push to github"
if [ "$(curl -o /dev/null -I -s -L -w "%{http_code}" https://github.com/cumhuriyet-bizim-platformu/derbent-releases/releases/download/core-v${CORE_VERSION}-derbent.${CORE_DERBENT}/hiddify-lib-linux-amd64.tar.gz)" = "404" ]; then 
    echo "Core v${CORE_VERSION} not Found"; 
    exit 3; 
fi


cversion_string=$(grep -e "^version:" pubspec.yaml | cut -d: -f2-)
cstr_version=`echo "${cversion_string}" | sed -E -n 's/ *([0-9]+\.[0-9]+\.[0-9]+).*/\1/p'`
[ "$cversion_string" == "" ] && { echo "getting old version error"; exit 1 ; }
cbuild_number=`echo "${cversion_string}" | sed -E -n 's/.*\+([0-9]+)$/\1/p'`
echo "Current Version Name:${cstr_version}   Build Number:${cbuild_number}"
# Derbent: release tags are v<upstream x.y.z>-derbent.<N>; a trailing .dev marks a pre-release.
read -p "new tag? (v<x.y.z>-derbent.<N> or v<x.y.z>-derbent.<N>.dev) : " TAG 
echo $TAG 
[[ "$TAG" =~ ^v([0-9]{1,2})\.([0-9]{1,2})\.([0-9]{1,2})-derbent\.([0-9]{1,2})(\.dev)?$ ]] || { echo "Incorrect tag. e.g., v4.1.2-derbent.1 or v4.1.2-derbent.1.dev"; exit 1; } 
VERSION_ARRAY=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}") 
N="${BASH_REMATCH[4]}" 
VERSION_STR="${VERSION_ARRAY[0]}.${VERSION_ARRAY[1]}.${VERSION_ARRAY[2]}" 
# Derbent: versionCode must grow with every derbent.N of one upstream version: (x*10000+y*100+z)*100+N.
BUILD_NUMBER=$(( (${VERSION_ARRAY[0]} * 10000 + ${VERSION_ARRAY[1]} * 100 + ${VERSION_ARRAY[2]}) * 100 + N )) 
echo "version: ${VERSION_STR}+${BUILD_NUMBER}" 
echo "====$cbuild_number"
SED "s/^version: .*/version: ${VERSION_STR}\+${BUILD_NUMBER}/g" pubspec.yaml 
SED "s/^msix_version: .*/msix_version: ${VERSION_ARRAY[0]}.${VERSION_ARRAY[1]}.${VERSION_ARRAY[2]}.${N}/g" windows/packaging/msix/make_config.yaml 
SED "s|CURRENT_PROJECT_VERSION = ${cbuild_number}|CURRENT_PROJECT_VERSION = ${BUILD_NUMBER}|g" ios/Runner.xcodeproj/project.pbxproj 
SED "s/MARKETING_VERSION = ${cstr_version}/MARKETING_VERSION = ${VERSION_STR}/g" ios/Runner.xcodeproj/project.pbxproj 

git tag ${TAG} > /dev/null 

gitchangelog > HISTORY.md || { git tag -d ${TAG}; echo "Please run pip install gitchangelog pystache mustache markdown"; exit 2; } 
git tag -d ${TAG} > /dev/null 
git add hiddify-core dependencies.properties ios/Runner.xcodeproj/project.pbxproj pubspec.yaml windows/packaging/msix/make_config.yaml HISTORY.md 
git commit -m "release: version ${TAG}" 
echo "creating git tag : ${TAG}" 
git push 
git tag ${TAG} 
git push -u origin HEAD --tags 
echo "Github Actions will detect the new tag and release the new version."
