package com.probnik;

import android.content.res.AssetManager;

public class ProbnikNative {
    static {
        System.loadLibrary("probnik_native");
    }

    public static native void init(AssetManager assetManager, String filesDir);
    public static native void resize(int width, int height);
    public static native void render();
    public static native void destroy();
}
