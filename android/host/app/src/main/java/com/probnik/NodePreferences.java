package com.probnik;

import android.content.Context;
import android.content.SharedPreferences;

import com.google.gson.Gson;
import com.google.gson.reflect.TypeToken;

import java.lang.reflect.Type;
import java.util.ArrayList;
import java.util.List;

public class NodePreferences {
    private static final String PREFS_NAME = "probnik_nodes";
    private static final String KEY_NODES = "paired_nodes";
    private static final String KEY_ACTIVE_NODE = "active_node";

    private final SharedPreferences prefs;
    private final Gson gson;

    public NodePreferences(Context context) {
        this.prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        this.gson = new Gson();
    }

    public static class PairedNode {
        public String node;       // e.g., "one@super-io"
        public String cookie;     // e.g., "secret_token"
        public String mode;       // "shortnames" or "longnames"
        public long lastConnected;
        public String lastStatus; // "connected", "failed", "unknown"

        public PairedNode() {}

        public PairedNode(String node, String cookie, String mode) {
            this.node = node;
            this.cookie = cookie;
            this.mode = mode;
            this.lastConnected = 0;
            this.lastStatus = "unknown";
        }

        public String getDisplayName() {
            return node;
        }

        public String getHost() {
            if (node != null && node.contains("@")) {
                return node.split("@")[1];
            }
            return "";
        }
    }

    public List<PairedNode> getPairedNodes() {
        String json = prefs.getString(KEY_NODES, "[]");
        Type listType = new TypeToken<ArrayList<PairedNode>>(){}.getType();
        List<PairedNode> nodes = gson.fromJson(json, listType);
        return nodes != null ? nodes : new ArrayList<>();
    }

    public void savePairedNodes(List<PairedNode> nodes) {
        String json = gson.toJson(nodes);
        prefs.edit().putString(KEY_NODES, json).apply();
    }

    public void addOrUpdateNode(PairedNode newNode) {
        List<PairedNode> nodes = getPairedNodes();

        // Remove existing node with same name
        nodes.removeIf(n -> n.node.equals(newNode.node));

        // Add to front of list
        nodes.add(0, newNode);

        savePairedNodes(nodes);
    }

    public void updateNodeStatus(String nodeName, String status) {
        List<PairedNode> nodes = getPairedNodes();
        for (PairedNode node : nodes) {
            if (node.node.equals(nodeName)) {
                node.lastStatus = status;
                node.lastConnected = System.currentTimeMillis();
                break;
            }
        }
        savePairedNodes(nodes);
    }

    public void removeNode(String nodeName) {
        List<PairedNode> nodes = getPairedNodes();
        nodes.removeIf(n -> n.node.equals(nodeName));
        savePairedNodes(nodes);
    }

    public String getActiveNode() {
        return prefs.getString(KEY_ACTIVE_NODE, null);
    }

    public void setActiveNode(String nodeName) {
        prefs.edit().putString(KEY_ACTIVE_NODE, nodeName).apply();
    }

    public PairedNode getNode(String nodeName) {
        List<PairedNode> nodes = getPairedNodes();
        for (PairedNode node : nodes) {
            if (node.node.equals(nodeName)) {
                return node;
            }
        }
        return null;
    }

    // Parse Erlang term from QR code
    // Format: {probnik_pair, 'node@host', cookie, [{mode, shortnames}]}
    public static PairedNode parseQrPayload(String payload) {
        if (payload == null || payload.isEmpty()) {
            return null;
        }

        // Remove whitespace
        payload = payload.trim();

        // Check for probnik_pair tuple
        if (!payload.startsWith("{probnik_pair,")) {
            return null;
        }

        try {
            // Extract node (atom with quotes or without)
            // Pattern: {probnik_pair, 'node@host', cookie, ...} or {probnik_pair, node@host, cookie, ...}
            String content = payload.substring(1, payload.length() - 1); // Remove outer braces
            String[] parts = splitErlangTuple(content);

            if (parts.length < 3) {
                return null;
            }

            // parts[0] = "probnik_pair"
            // parts[1] = node (may be quoted)
            // parts[2] = cookie (may be quoted)
            // parts[3] = options (optional)

            String node = unquoteAtom(parts[1].trim());
            String cookie = unquoteAtom(parts[2].trim());

            // Default mode
            String mode = "shortnames";

            // Parse options if present
            if (parts.length > 3) {
                String opts = parts[3].trim();
                if (opts.contains("longnames")) {
                    mode = "longnames";
                }
            }

            // Validate node format
            if (!node.contains("@")) {
                return null;
            }

            return new PairedNode(node, cookie, mode);
        } catch (Exception e) {
            return null;
        }
    }

    private static String[] splitErlangTuple(String content) {
        List<String> parts = new ArrayList<>();
        int depth = 0;
        boolean inQuote = false;
        StringBuilder current = new StringBuilder();

        for (int i = 0; i < content.length(); i++) {
            char c = content.charAt(i);

            if (c == '\'' && (i == 0 || content.charAt(i-1) != '\\')) {
                inQuote = !inQuote;
                current.append(c);
            } else if (!inQuote && (c == '{' || c == '[')) {
                depth++;
                current.append(c);
            } else if (!inQuote && (c == '}' || c == ']')) {
                depth--;
                current.append(c);
            } else if (!inQuote && c == ',' && depth == 0) {
                parts.add(current.toString());
                current = new StringBuilder();
            } else {
                current.append(c);
            }
        }

        if (current.length() > 0) {
            parts.add(current.toString());
        }

        return parts.toArray(new String[0]);
    }

    private static String unquoteAtom(String atom) {
        if (atom.startsWith("'") && atom.endsWith("'")) {
            return atom.substring(1, atom.length() - 1);
        }
        return atom;
    }
}
