package com.probnik;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.util.Log;
import android.view.View;
import android.view.WindowManager;

import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStreamWriter;

public class HostActivity extends Activity {
    private static final String TAG = "HostActivity";
    private ProbnikGLSurfaceView glView;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN);

        // Get connection info from intent
        Intent intent = getIntent();
        String node = intent.getStringExtra("node");
        String cookie = intent.getStringExtra("cookie");
        String mode = intent.getStringExtra("mode");

        if (node != null && cookie != null) {
            writeConnectionConfig(node, cookie, mode != null ? mode : "shortnames");
        }

        // Initialize native code with AssetManager and files directory
        ProbnikNative.init(getAssets(), getFilesDir().getAbsolutePath());

        glView = new ProbnikGLSurfaceView(this);
        setContentView(glView);
        hideSystemUI();
    }

    private void writeConnectionConfig(String node, String cookie, String mode) {
        try {
            // Write to files dir where Elixir can read it
            File configFile = new File(getFilesDir(), "connection.config");

            // Erlang term format that can be read with :file.consult/1
            // {node, 'one@super-io'}.
            // {cookie, 'secret_token'}.
            // {mode, shortnames}.
            String content = String.format(
                "{node, '%s'}.\n{cookie, '%s'}.\n{mode, %s}.\n",
                node, cookie, mode
            );

            FileOutputStream fos = new FileOutputStream(configFile);
            OutputStreamWriter writer = new OutputStreamWriter(fos);
            writer.write(content);
            writer.close();

            Log.i(TAG, "Connection config written: " + configFile.getAbsolutePath());
            Log.i(TAG, "  node=" + node + " cookie=" + cookie + " mode=" + mode);
        } catch (Exception e) {
            Log.e(TAG, "Failed to write connection config", e);
        }
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
        hideSystemUI();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) {
            hideSystemUI();
        }
    }

    @Override
    protected void onDestroy() {
        ProbnikNative.destroy();
        super.onDestroy();
    }

    @Override
    public void onBackPressed() {
        // Go back to pairing screen to select another node
        Log.i(TAG, "Back pressed - returning to pairing screen");
        Intent intent = new Intent(this, PairingActivity.class);
        intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP);
        startActivity(intent);
        finish();
    }

    private void hideSystemUI() {
        View decorView = getWindow().getDecorView();
        int flags = View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                | View.SYSTEM_UI_FLAG_FULLSCREEN
                | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_LAYOUT_STABLE;
        decorView.setSystemUiVisibility(flags);
    }
}
