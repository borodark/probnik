# Probnik ProGuard Rules

# Keep JNI methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep the native interface class
-keep class com.probnik.ProbnikNative { *; }

# Keep Activity classes
-keep class com.probnik.HostActivity { *; }
-keep class com.probnik.ProbnikRenderer { *; }
-keep class com.probnik.ProbnikGLSurfaceView { *; }
