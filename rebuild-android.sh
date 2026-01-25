./android/build_release.sh
cd android/host
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell pm clear com.probnik
