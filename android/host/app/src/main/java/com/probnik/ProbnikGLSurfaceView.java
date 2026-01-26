package com.probnik;

import android.content.Context;
import android.opengl.GLSurfaceView;
import android.view.MotionEvent;

public class ProbnikGLSurfaceView extends GLSurfaceView {
    private final ProbnikRenderer renderer;

    public ProbnikGLSurfaceView(Context context) {
        super(context);
        setEGLContextClientVersion(3); // OpenGL ES 3.0
        renderer = new ProbnikRenderer();
        setRenderer(renderer);
        setRenderMode(GLSurfaceView.RENDERMODE_CONTINUOUSLY);
    }

    @Override
    public boolean onTouchEvent(MotionEvent event) {
        int action = event.getActionMasked();
        float x = event.getX();
        float y = event.getY();

        int sendAction;
        switch (action) {
            case MotionEvent.ACTION_DOWN:
            case MotionEvent.ACTION_POINTER_DOWN:
                sendAction = 0;
                break;
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_POINTER_UP:
            case MotionEvent.ACTION_CANCEL:
                sendAction = 1;
                break;
            case MotionEvent.ACTION_MOVE:
                sendAction = 2;
                break;
            default:
                return true;
        }

        ProbnikNative.onTouch(sendAction, x, y);
        return true;
    }
}
