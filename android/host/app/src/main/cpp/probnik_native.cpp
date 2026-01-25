#include <jni.h>
#include <android/log.h>
#include <android/asset_manager.h>
#include <android/asset_manager_jni.h>
#include <GLES3/gl3.h>

#include "scenic_local/renderer_android.h"

#include <string>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <dirent.h>
#include <errno.h>
#include <cstring>
#include <vector>
#include <fstream>
#include <sstream>
#include <thread>
#include <mutex>
#include <atomic>
#include <deque>

#define LOG_TAG "ProbnikNative"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// Message types from Scenic driver
#define MSG_CLEAR_COLOR 1
#define MSG_UPDATE_SCENE 2
#define MSG_DELETE_SCRIPTS 3
#define MSG_RESET 4
#define MSG_PUT_FONT 5
#define MSG_PUT_IMAGE 6

static std::string g_release_root;
static std::string g_erts_bin;
static std::string g_socket_path;
static pid_t g_beam_pid = -1;
static int g_screen_width = 0;
static int g_screen_height = 0;
static int g_server_socket = -1;
static int g_client_socket = -1;
static std::atomic<bool> g_running{false};
static std::thread g_socket_thread;
static std::mutex g_render_mutex;
static std::atomic<bool> g_logged_first_msg{false};
static std::deque<std::pair<uint8_t, std::vector<uint8_t>>> g_pending_msgs;

// Render state
static GLuint g_test_program = 0;
static GLuint g_test_vao = 0;
static GLuint g_test_vbo = 0;
static bool g_test_ready = false;
static bool g_renderer_ready = false;
static bool g_has_scene = false;

// Forward declarations
static bool extract_assets(JNIEnv* env, jobject asset_manager, const std::string& dest_dir);
static void make_executable(const std::string& path);
static bool start_beam();
static void start_socket_server();
static void socket_server_thread();
static void handle_message(uint8_t type, const std::vector<uint8_t>& payload);
static void process_pending_messages();
static std::string read_asset_manifest(AAssetManager* mgr);
static bool write_file(const std::string& path, const std::string& content);
static bool copy_file(const std::string& src, const std::string& dst);
static void ensure_test_triangle();
static GLuint compile_shader(GLenum type, const char* src);

extern "C" {

JNIEXPORT void JNICALL
Java_com_probnik_ProbnikNative_init(JNIEnv* env, jclass clazz,
                                     jobject asset_manager, jstring files_dir) {
    const char* files_dir_cstr = env->GetStringUTFChars(files_dir, nullptr);
    g_release_root = std::string(files_dir_cstr) + "/erlang";
    g_socket_path = std::string(files_dir_cstr) + "/../cache/scenic.sock";
    env->ReleaseStringUTFChars(files_dir, files_dir_cstr);

    LOGI("init() - release_root: %s", g_release_root.c_str());
    LOGI("init() - socket_path: %s", g_socket_path.c_str());

    AAssetManager* mgr = AAssetManager_fromJava(env, asset_manager);
    if (!mgr) {
        LOGE("Failed to get AAssetManager");
        return;
    }

    std::string manifest_content = read_asset_manifest(mgr);
    std::string marker = g_release_root + "/.extracted_manifest";
    bool needs_extract = true;

    if (!manifest_content.empty()) {
        std::ifstream in(marker);
        if (in) {
            std::stringstream buffer;
            buffer << in.rdbuf();
            if (buffer.str() == manifest_content) {
                needs_extract = false;
            }
        }
    }

    if (needs_extract) {
        LOGI("Extracting assets...");
        if (!extract_assets(env, asset_manager, g_release_root)) {
            LOGE("Failed to extract assets!");
            return;
        }
        if (!manifest_content.empty()) {
            write_file(marker, manifest_content);
        }
        LOGI("Assets extracted successfully");
    } else {
        LOGI("Assets already extracted (manifest match)");
    }

    // Find ERTS version directory
    std::string erts_dir = g_release_root + "/erts";
    DIR* dir = opendir(erts_dir.c_str());
    if (dir) {
        struct dirent* entry;
        while ((entry = readdir(dir)) != nullptr) {
            if (strncmp(entry->d_name, "erts-", 5) == 0) {
                g_erts_bin = erts_dir + "/" + entry->d_name + "/bin";
                break;
            }
        }
        closedir(dir);
    }

    if (g_erts_bin.empty()) {
        LOGE("Could not find ERTS bin directory!");
        return;
    }

    LOGI("ERTS bin: %s", g_erts_bin.c_str());

    // Make binaries executable
    make_executable(g_erts_bin + "/beam.smp");
    make_executable(g_erts_bin + "/erlexec");
    make_executable(g_erts_bin + "/erl_child_setup");
    make_executable(g_erts_bin + "/epmd");

    // Start socket server before BEAM
    start_socket_server();

    // Start BEAM
    if (!start_beam()) {
        LOGE("Failed to start BEAM!");
    }
}

JNIEXPORT void JNICALL
Java_com_probnik_ProbnikNative_resize(JNIEnv* env, jclass clazz, jint width, jint height) {
    g_screen_width = width;
    g_screen_height = height;
    LOGI("resize(%d, %d)", width, height);

    if (g_renderer_ready) {
        scenic_android_resize(g_screen_width, g_screen_height, 1.0f);
    }
}

JNIEXPORT void JNICALL
Java_com_probnik_ProbnikNative_render(JNIEnv* env, jclass clazz) {
    std::lock_guard<std::mutex> lock(g_render_mutex);

    if (g_screen_width > 0 && g_screen_height > 0) {
        glViewport(0, 0, g_screen_width, g_screen_height);
    }

    if (!g_renderer_ready && g_screen_width > 0 && g_screen_height > 0) {
        scenic_android_init(g_screen_width, g_screen_height, 1.0f);
        g_renderer_ready = true;
    }

    if (g_renderer_ready) {
        process_pending_messages();
    }

    if (g_renderer_ready && g_has_scene) {
        scenic_android_render();
    } else {
        ensure_test_triangle();
        if (g_test_ready) {
            glUseProgram(g_test_program);
            glBindVertexArray(g_test_vao);
            glDrawArrays(GL_TRIANGLES, 0, 3);
            glBindVertexArray(0);
            glUseProgram(0);
        }
    }

    static bool first_render = true;
    if (first_render) {
        LOGI("First render frame");
        first_render = false;
    }
}

JNIEXPORT void JNICALL
Java_com_probnik_ProbnikNative_destroy(JNIEnv* env, jclass clazz) {
    LOGI("destroy()");

    g_running = false;

    {
        std::lock_guard<std::mutex> lock(g_render_mutex);
        scenic_android_shutdown();
        g_renderer_ready = false;
        g_has_scene = false;
    }

    if (g_client_socket >= 0) {
        close(g_client_socket);
        g_client_socket = -1;
    }

    if (g_server_socket >= 0) {
        close(g_server_socket);
        g_server_socket = -1;
    }

    if (g_socket_thread.joinable()) {
        g_socket_thread.join();
    }

    if (g_beam_pid > 0) {
        kill(g_beam_pid, SIGTERM);
        int status;
        waitpid(g_beam_pid, &status, 0);
        g_beam_pid = -1;
        LOGI("BEAM process terminated");
    }

    unlink(g_socket_path.c_str());
}

} // extern "C"

static void start_socket_server() {
    // Remove old socket file
    unlink(g_socket_path.c_str());

    g_server_socket = socket(AF_UNIX, SOCK_STREAM, 0);
    if (g_server_socket < 0) {
        LOGE("Failed to create socket: %s", strerror(errno));
        return;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, g_socket_path.c_str(), sizeof(addr.sun_path) - 1);

    if (bind(g_server_socket, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        LOGE("Failed to bind socket: %s", strerror(errno));
        close(g_server_socket);
        g_server_socket = -1;
        return;
    }

    if (listen(g_server_socket, 1) < 0) {
        LOGE("Failed to listen on socket: %s", strerror(errno));
        close(g_server_socket);
        g_server_socket = -1;
        return;
    }

    chmod(g_socket_path.c_str(), 0777);

    LOGI("Socket server listening on %s", g_socket_path.c_str());

    g_running = true;
    g_socket_thread = std::thread(socket_server_thread);
}

static void socket_server_thread() {
    LOGI("Socket server thread started");

    while (g_running) {
        fd_set read_fds;
        FD_ZERO(&read_fds);
        FD_SET(g_server_socket, &read_fds);

        struct timeval timeout;
        timeout.tv_sec = 1;
        timeout.tv_usec = 0;

        int max_fd = g_server_socket;
        if (g_client_socket >= 0) {
            FD_SET(g_client_socket, &read_fds);
            max_fd = std::max(max_fd, g_client_socket);
        }

        int ret = select(max_fd + 1, &read_fds, nullptr, nullptr, &timeout);
        if (ret < 0) {
            if (errno != EINTR) {
                LOGE("select() failed: %s", strerror(errno));
            }
            continue;
        }

        if (ret == 0) continue;

        // Check for new connections
        if (FD_ISSET(g_server_socket, &read_fds)) {
            int client = accept(g_server_socket, nullptr, nullptr);
            if (client >= 0) {
                if (g_client_socket >= 0) {
                    close(g_client_socket);
                }
                g_client_socket = client;
                LOGI("Scenic driver connected");
            }
        }

        // Check for data from client
        if (g_client_socket >= 0 && FD_ISSET(g_client_socket, &read_fds)) {
            // Read message header: [type:1][length:4]
            uint8_t header[5];
            ssize_t n = recv(g_client_socket, header, 5, MSG_WAITALL);
            if (n <= 0) {
                LOGI("Scenic driver disconnected");
                close(g_client_socket);
                g_client_socket = -1;
                continue;
            }

            uint8_t msg_type = header[0];
            uint32_t length = (header[1] << 24) | (header[2] << 16) | (header[3] << 8) | header[4];

            if (!g_logged_first_msg.exchange(true)) {
                LOGI("First Scenic message: type=%u len=%u", msg_type, length);
            }

            // Read payload
            std::vector<uint8_t> payload(length);
            if (length > 0) {
                n = recv(g_client_socket, payload.data(), length, MSG_WAITALL);
                if (n != (ssize_t)length) {
                    LOGE("Failed to read payload");
                    continue;
                }
            }

            handle_message(msg_type, payload);
        }
    }

    LOGI("Socket server thread exiting");
}

static void handle_message(uint8_t type, const std::vector<uint8_t>& payload) {
    std::lock_guard<std::mutex> lock(g_render_mutex);
    g_pending_msgs.emplace_back(type, payload);
}

static void process_pending_messages() {
    while (!g_pending_msgs.empty()) {
        auto msg = std::move(g_pending_msgs.front());
        g_pending_msgs.pop_front();
        const uint8_t type = msg.first;
        const std::vector<uint8_t>& payload = msg.second;

    switch (type) {
        case MSG_CLEAR_COLOR: {
            if (payload.size() >= 16) {
                float r, g, b, a;
                memcpy(&r, payload.data(), 4);
                memcpy(&g, payload.data() + 4, 4);
                memcpy(&b, payload.data() + 8, 4);
                memcpy(&a, payload.data() + 12, 4);
                scenic_android_set_clear_color(r, g, b, a);
                LOGI("Clear color: %.2f, %.2f, %.2f, %.2f", r, g, b, a);
            }
            break;
        }

        case MSG_UPDATE_SCENE: {
            if (payload.empty()) {
                LOGI("Update scene: empty payload");
                break;
            }

            scenic_android_put_script(payload.data(), static_cast<int>(payload.size()));
            g_has_scene = true;
            break;
        }

        case MSG_DELETE_SCRIPTS: {
            if (payload.empty()) {
                LOGI("Delete scripts: empty payload");
                break;
            }

            scenic_android_delete_script(payload.data(), static_cast<int>(payload.size()));
            break;
        }

        case MSG_RESET: {
            LOGI("Reset scene");
            scenic_android_reset();
            break;
        }

        case MSG_PUT_FONT: {
            if (payload.empty()) {
                LOGI("Put font: empty payload");
                break;
            }
            scenic_android_put_font(payload.data(), static_cast<int>(payload.size()));
            break;
        }

        case MSG_PUT_IMAGE: {
            if (payload.empty()) {
                LOGI("Put image: empty payload");
                break;
            }
            scenic_android_put_image(payload.data(), static_cast<int>(payload.size()));
            break;
        }

        default:
            LOGI("Unknown message type: %d", type);
            break;
    }
    }
}

static void beam_output_reader(int fd, const char* prefix) {
    char buffer[1024];
    ssize_t n;
    std::string line;

    while ((n = read(fd, buffer, sizeof(buffer) - 1)) > 0) {
        buffer[n] = '\0';
        line += buffer;

        // Output complete lines
        size_t pos;
        while ((pos = line.find('\n')) != std::string::npos) {
            std::string msg = line.substr(0, pos);
            if (!msg.empty()) {
                __android_log_print(ANDROID_LOG_INFO, "BEAM", "[%s] %s", prefix, msg.c_str());
            }
            line = line.substr(pos + 1);
        }
    }

    // Output remaining content
    if (!line.empty()) {
        __android_log_print(ANDROID_LOG_INFO, "BEAM", "[%s] %s", prefix, line.c_str());
    }
}

static bool start_beam() {
    LOGI("Starting BEAM...");

    std::string beam_path = g_erts_bin + "/beam.smp";
    std::string releases_dir = g_release_root + "/releases";
    std::string release_vsn = "0.1.0";
    std::string boot_file = releases_dir + "/" + release_vsn + "/start";
    std::string vm_args_file = releases_dir + "/" + release_vsn + "/vm.args";
    std::string sys_config = releases_dir + "/" + release_vsn + "/sys";
    std::string sys_config_file = releases_dir + "/" + release_vsn + "/sys.config";
    std::string release_tmp = g_release_root + "/tmp";
    std::string lib_dir = g_release_root + "/lib";

    // ROOTDIR should be the erlang root (contains lib/, releases/, erts-VERSION/)
    std::string root_dir = g_release_root + "/erts";

    LOGI("BEAM path: %s", beam_path.c_str());
    LOGI("Boot file: %s", boot_file.c_str());
    LOGI("VM args: %s", vm_args_file.c_str());
    LOGI("Root dir: %s", root_dir.c_str());
    LOGI("Lib dir: %s", lib_dir.c_str());

    // Create pipes for stdout/stderr capture
    int stdout_pipe[2];
    int stderr_pipe[2];
    if (pipe(stdout_pipe) < 0 || pipe(stderr_pipe) < 0) {
        LOGE("Failed to create pipes: %s", strerror(errno));
        return false;
    }

    pid_t pid = fork();
    if (pid == 0) {
        // Child process

        // Redirect stdout/stderr to pipes
        close(stdout_pipe[0]);
        close(stderr_pipe[0]);
        dup2(stdout_pipe[1], STDOUT_FILENO);
        dup2(stderr_pipe[1], STDERR_FILENO);
        close(stdout_pipe[1]);
        close(stderr_pipe[1]);

        // Set environment
        setenv("HOME", g_release_root.c_str(), 1);
        setenv("ROOTDIR", root_dir.c_str(), 1);
        setenv("BINDIR", g_erts_bin.c_str(), 1);  // Must point to erts-VERSION/bin
        setenv("EMU", "beam", 1);
        setenv("PROGNAME", "probnik", 1);
        setenv("RELEASE_ROOT", g_release_root.c_str(), 1);
        setenv("RELEASE_VSN", release_vsn.c_str(), 1);
        setenv("RELEASE_NAME", "probnik", 1);
        setenv("RELEASE_CONFIG_DIR", (releases_dir + "/" + release_vsn).c_str(), 1);
        mkdir(release_tmp.c_str(), 0755);
        std::string release_sys_config = release_tmp + "/probnik-" + release_vsn + ".runtime";
        std::string release_sys_config_file = release_sys_config + ".config";
        if (!copy_file(sys_config_file, release_sys_config_file)) {
            fprintf(stderr, "Failed to copy sys.config to %s\n", release_sys_config_file.c_str());
        }
        setenv("RELEASE_TMP", release_tmp.c_str(), 1);
        setenv("RELEASE_SYS_CONFIG", release_sys_config.c_str(), 1);
        setenv("ANDROID_ROOT", "/system", 1);  // Signal to Elixir that we're on Android

        // Log environment for debugging
        fprintf(stderr, "HOME=%s\n", g_release_root.c_str());
        fprintf(stderr, "ROOTDIR=%s\n", root_dir.c_str());
        fprintf(stderr, "BINDIR=%s\n", g_erts_bin.c_str());
        fflush(stderr);

        // Use erlexec instead of beam.smp directly
        std::string erlexec_path = g_erts_bin + "/erlexec";

        std::vector<const char*> args;
        args.push_back(erlexec_path.c_str());
        args.push_back("-boot");
        args.push_back(boot_file.c_str());
        args.push_back("-boot_var");
        args.push_back("RELEASE_LIB");
        args.push_back(lib_dir.c_str());
        args.push_back("-args_file");
        args.push_back(vm_args_file.c_str());
        args.push_back("-config");
        args.push_back(sys_config.c_str());
        args.push_back("-noshell");
        args.push_back("-noinput");
        args.push_back(nullptr);

        // Make erlexec executable
        chmod(erlexec_path.c_str(), 0755);

        // Log args for debugging
        for (size_t i = 0; args[i] != nullptr; i++) {
            fprintf(stderr, "arg[%zu]: %s\n", i, args[i]);
        }
        fflush(stderr);

        execv(erlexec_path.c_str(), const_cast<char* const*>(args.data()));
        fprintf(stderr, "execv failed: %s\n", strerror(errno));
        _exit(1);
    } else if (pid > 0) {
        // Parent process
        close(stdout_pipe[1]);
        close(stderr_pipe[1]);

        g_beam_pid = pid;
        LOGI("BEAM started with PID %d", pid);

        // Start threads to read BEAM output
        std::thread stdout_thread(beam_output_reader, stdout_pipe[0], "stdout");
        std::thread stderr_thread(beam_output_reader, stderr_pipe[0], "stderr");
        stdout_thread.detach();
        stderr_thread.detach();

        return true;
    } else {
        LOGE("fork() failed: %s", strerror(errno));
        close(stdout_pipe[0]);
        close(stdout_pipe[1]);
        close(stderr_pipe[0]);
        close(stderr_pipe[1]);
        return false;
    }
}

static void make_executable(const std::string& path) {
    if (chmod(path.c_str(), 0755) != 0) {
        LOGE("chmod failed for %s: %s", path.c_str(), strerror(errno));
    }
}

static bool copy_asset_file(AAssetManager* mgr, const std::string& asset_path, const std::string& dest_path) {
    AAsset* asset = AAssetManager_open(mgr, asset_path.c_str(), AASSET_MODE_STREAMING);
    if (!asset) return false;

    FILE* out = fopen(dest_path.c_str(), "wb");
    if (!out) {
        AAsset_close(asset);
        return false;
    }

    char buf[8192];
    int nb;
    while ((nb = AAsset_read(asset, buf, sizeof(buf))) > 0) {
        fwrite(buf, 1, nb, out);
    }

    fclose(out);
    AAsset_close(asset);
    return true;
}

static std::string read_asset_manifest(AAssetManager* mgr) {
    AAsset* manifest = AAssetManager_open(mgr, "erlang/file_manifest.txt", AASSET_MODE_BUFFER);
    if (!manifest) {
        LOGE("No file_manifest.txt found");
        return "";
    }

    const char* data = static_cast<const char*>(AAsset_getBuffer(manifest));
    off_t length = AAsset_getLength(manifest);
    std::string manifest_content(data, length);
    AAsset_close(manifest);
    return manifest_content;
}

static bool write_file(const std::string& path, const std::string& content) {
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) return false;
    out.write(content.data(), static_cast<std::streamsize>(content.size()));
    return out.good();
}

static bool copy_file(const std::string& src, const std::string& dst) {
    std::ifstream in(src, std::ios::binary);
    if (!in) return false;
    std::ofstream out(dst, std::ios::binary | std::ios::trunc);
    if (!out) return false;
    out << in.rdbuf();
    return out.good();
}

static GLuint compile_shader(GLenum type, const char* src) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &src, nullptr);
    glCompileShader(shader);
    GLint ok = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        GLint len = 0;
        glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &len);
        std::string log(len, '\0');
        if (len > 0) {
            glGetShaderInfoLog(shader, len, nullptr, log.data());
        }
        LOGE("Shader compile failed: %s", log.c_str());
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

static void ensure_test_triangle() {
    if (g_test_ready) return;

    const char* vs_src =
        "#version 300 es\n"
        "layout(location = 0) in vec2 a_pos;\n"
        "layout(location = 1) in vec3 a_color;\n"
        "out vec3 v_color;\n"
        "void main() {\n"
        "  v_color = a_color;\n"
        "  gl_Position = vec4(a_pos, 0.0, 1.0);\n"
        "}\n";

    const char* fs_src =
        "#version 300 es\n"
        "precision mediump float;\n"
        "in vec3 v_color;\n"
        "out vec4 fragColor;\n"
        "void main() {\n"
        "  fragColor = vec4(v_color, 1.0);\n"
        "}\n";

    GLuint vs = compile_shader(GL_VERTEX_SHADER, vs_src);
    GLuint fs = compile_shader(GL_FRAGMENT_SHADER, fs_src);
    if (!vs || !fs) return;

    g_test_program = glCreateProgram();
    glAttachShader(g_test_program, vs);
    glAttachShader(g_test_program, fs);
    glLinkProgram(g_test_program);
    glDeleteShader(vs);
    glDeleteShader(fs);

    GLint linked = GL_FALSE;
    glGetProgramiv(g_test_program, GL_LINK_STATUS, &linked);
    if (!linked) {
        GLint len = 0;
        glGetProgramiv(g_test_program, GL_INFO_LOG_LENGTH, &len);
        std::string log(len, '\0');
        if (len > 0) {
            glGetProgramInfoLog(g_test_program, len, nullptr, log.data());
        }
        LOGE("Program link failed: %s", log.c_str());
        glDeleteProgram(g_test_program);
        g_test_program = 0;
        return;
    }

    const GLfloat verts[] = {
        // x, y,    r, g, b
         0.0f,  0.8f, 1.0f, 0.2f, 0.2f,
        -0.8f, -0.8f, 0.2f, 1.0f, 0.2f,
         0.8f, -0.8f, 0.2f, 0.2f, 1.0f
    };

    glGenVertexArrays(1, &g_test_vao);
    glGenBuffers(1, &g_test_vbo);
    glBindVertexArray(g_test_vao);
    glBindBuffer(GL_ARRAY_BUFFER, g_test_vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 5 * sizeof(GLfloat), (void*)0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 5 * sizeof(GLfloat),
                          (void*)(2 * sizeof(GLfloat)));
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glBindVertexArray(0);

    g_test_ready = true;
    LOGI("Test triangle initialized");
}


static bool extract_assets(JNIEnv* env, jobject asset_manager_obj, const std::string& dest_dir) {
    AAssetManager* mgr = AAssetManager_fromJava(env, asset_manager_obj);
    if (!mgr) {
        LOGE("Failed to get AAssetManager");
        return false;
    }

    mkdir(dest_dir.c_str(), 0755);

    std::string manifest_content = read_asset_manifest(mgr);
    if (manifest_content.empty()) {
        return false;
    }

    std::istringstream iss(manifest_content);
    std::string line;
    int count = 0;
    while (std::getline(iss, line)) {
        if (line.empty() || line[0] == '#') continue;

        std::string src = "erlang/" + line;
        std::string dst = dest_dir + "/" + line;

        size_t pos = 0;
        while ((pos = line.find('/', pos + 1)) != std::string::npos) {
            std::string parent = dest_dir + "/" + line.substr(0, pos);
            mkdir(parent.c_str(), 0755);
        }

        bool copied = copy_asset_file(mgr, src, dst);
        if (!copied) {
            size_t scenic_pos = line.find("/__scenic/");
            if (scenic_pos != std::string::npos) {
                std::string alt_line = line;
                alt_line.replace(scenic_pos, strlen("/__scenic/"), "/scenic/");
                std::string alt_src = "erlang/" + alt_line;
                copied = copy_asset_file(mgr, alt_src, dst);
            }
        }

        if (copied) {
            count++;
        } else {
            LOGE("Missing asset in APK: %s", src.c_str());
        }
    }

    LOGI("Extracted %d files", count);
    return true;
}
