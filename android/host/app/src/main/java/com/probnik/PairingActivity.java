package com.probnik;

import android.Manifest;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.TextView;
import android.widget.Toast;

import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.content.ContextCompat;
import androidx.recyclerview.widget.LinearLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.List;
import java.util.Locale;

public class PairingActivity extends AppCompatActivity {
    private static final int REQUEST_QR_SCAN = 1001;

    private NodePreferences nodePrefs;
    private RecyclerView nodesList;
    private NodesAdapter adapter;
    private View emptyView;

    private final ActivityResultLauncher<String> cameraPermissionLauncher =
        registerForActivityResult(new ActivityResultContracts.RequestPermission(), granted -> {
            if (granted) {
                launchQrScanner();
            } else {
                Toast.makeText(this, "Camera permission required for QR scanning", Toast.LENGTH_LONG).show();
            }
        });

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_pairing);

        nodePrefs = new NodePreferences(this);

        nodesList = findViewById(R.id.nodes_list);
        emptyView = findViewById(R.id.empty_view);
        Button scanButton = findViewById(R.id.scan_button);

        nodesList.setLayoutManager(new LinearLayoutManager(this));
        adapter = new NodesAdapter();
        nodesList.setAdapter(adapter);

        scanButton.setOnClickListener(v -> checkCameraAndScan());

        // Always show the pairing screen - user selects node or scans new one
    }

    @Override
    protected void onResume() {
        super.onResume();
        refreshNodesList();
    }

    private void refreshNodesList() {
        List<NodePreferences.PairedNode> nodes = nodePrefs.getPairedNodes();
        adapter.setNodes(nodes);

        if (nodes.isEmpty()) {
            nodesList.setVisibility(View.GONE);
            emptyView.setVisibility(View.VISIBLE);
        } else {
            nodesList.setVisibility(View.VISIBLE);
            emptyView.setVisibility(View.GONE);
        }
    }

    private void checkCameraAndScan() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
                == PackageManager.PERMISSION_GRANTED) {
            launchQrScanner();
        } else {
            cameraPermissionLauncher.launch(Manifest.permission.CAMERA);
        }
    }

    private void launchQrScanner() {
        Intent intent = new Intent(this, QrScannerActivity.class);
        startActivityForResult(intent, REQUEST_QR_SCAN);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);

        if (requestCode == REQUEST_QR_SCAN && resultCode == RESULT_OK && data != null) {
            String qrPayload = data.getStringExtra("qr_payload");
            if (qrPayload != null) {
                handleQrResult(qrPayload);
            }
        }
    }

    private void handleQrResult(String payload) {
        NodePreferences.PairedNode node = NodePreferences.parseQrPayload(payload);

        if (node == null) {
            Toast.makeText(this, "Invalid QR code format", Toast.LENGTH_LONG).show();
            return;
        }

        // Save and connect
        nodePrefs.addOrUpdateNode(node);
        connectToNode(node);
    }

    private void connectToNode(NodePreferences.PairedNode node) {
        nodePrefs.setActiveNode(node.node);

        Intent intent = new Intent(this, HostActivity.class);
        intent.putExtra("node", node.node);
        intent.putExtra("cookie", node.cookie);
        intent.putExtra("mode", node.mode);
        startActivity(intent);
        finish();
    }

    private class NodesAdapter extends RecyclerView.Adapter<NodesAdapter.NodeViewHolder> {
        private List<NodePreferences.PairedNode> nodes;

        void setNodes(List<NodePreferences.PairedNode> nodes) {
            this.nodes = nodes;
            notifyDataSetChanged();
        }

        @Override
        public NodeViewHolder onCreateViewHolder(ViewGroup parent, int viewType) {
            View view = LayoutInflater.from(parent.getContext())
                .inflate(R.layout.item_node, parent, false);
            return new NodeViewHolder(view);
        }

        @Override
        public void onBindViewHolder(NodeViewHolder holder, int position) {
            NodePreferences.PairedNode node = nodes.get(position);
            holder.bind(node);
        }

        @Override
        public int getItemCount() {
            return nodes != null ? nodes.size() : 0;
        }

        class NodeViewHolder extends RecyclerView.ViewHolder {
            TextView nodeName;
            TextView nodeStatus;
            TextView lastConnected;
            View deleteButton;

            NodeViewHolder(View itemView) {
                super(itemView);
                nodeName = itemView.findViewById(R.id.node_name);
                nodeStatus = itemView.findViewById(R.id.node_status);
                lastConnected = itemView.findViewById(R.id.last_connected);
                deleteButton = itemView.findViewById(R.id.delete_button);
            }

            void bind(NodePreferences.PairedNode node) {
                nodeName.setText(node.getDisplayName());
                nodeStatus.setText(node.lastStatus);

                if (node.lastConnected > 0) {
                    SimpleDateFormat sdf = new SimpleDateFormat("MMM d, HH:mm", Locale.getDefault());
                    lastConnected.setText("Last: " + sdf.format(new Date(node.lastConnected)));
                    lastConnected.setVisibility(View.VISIBLE);
                } else {
                    lastConnected.setVisibility(View.GONE);
                }

                itemView.setOnClickListener(v -> connectToNode(node));

                deleteButton.setOnClickListener(v -> {
                    nodePrefs.removeNode(node.node);
                    refreshNodesList();
                });
            }
        }
    }
}
