package com.probnik;

import android.app.Activity;
import android.os.Bundle;
import android.view.WindowManager;

public class HostActivity extends Activity {
    private ProbnikGLSurfaceView glView;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        // Initialize native code with AssetManager and files directory
        ProbnikNative.init(getAssets(), getFilesDir().getAbsolutePath());

        glView = new ProbnikGLSurfaceView(this);
        setContentView(glView);
    }

    @Override
    protected void onPause() {
        super.onPause();
        glView.onPause();
    }

    @Override
    protected void onResume() {
        super.onResume();
        glView.onResume();
    }

    @Override
    protected void onDestroy() {
        ProbnikNative.destroy();
        super.onDestroy();
    }
}
