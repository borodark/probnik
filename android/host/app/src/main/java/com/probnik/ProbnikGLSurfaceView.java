package com.probnik;

import android.content.Context;
import android.opengl.GLSurfaceView;

public class ProbnikGLSurfaceView extends GLSurfaceView {
    private final ProbnikRenderer renderer;

    public ProbnikGLSurfaceView(Context context) {
        super(context);
        setEGLContextClientVersion(3); // OpenGL ES 3.0
        renderer = new ProbnikRenderer();
        setRenderer(renderer);
        setRenderMode(GLSurfaceView.RENDERMODE_CONTINUOUSLY);
    }
}
