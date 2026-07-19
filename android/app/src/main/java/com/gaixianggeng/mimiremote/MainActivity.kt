package com.gaixianggeng.mimiremote

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.weight
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.gaixianggeng.mimiremote.ui.ConnectionState
import com.gaixianggeng.mimiremote.ui.RemoteViewModel

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                MimiRemoteApp(initialIntent = intent)
            }
        }
    }
}

@Composable
private fun MimiRemoteApp(
    initialIntent: Intent?,
    remoteViewModel: RemoteViewModel = viewModel(),
) {
    val state by remoteViewModel.state.collectAsStateWithLifecycle()
    LaunchedEffect(initialIntent?.dataString) {
        if (initialIntent?.scheme == "mimiremote") {
            initialIntent.data?.getQueryParameter("endpoint")?.let(remoteViewModel::setEndpoint)
            initialIntent.data?.getQueryParameter("token")?.let(remoteViewModel::setToken)
        }
    }

    if (state.connection == ConnectionState.Connected) {
        WorkbenchScreen(remoteViewModel)
    } else {
        PairingScreen(
            endpoint = state.endpoint,
            token = state.token,
            connection = state.connection,
            error = state.error,
            onEndpointChange = remoteViewModel::setEndpoint,
            onTokenChange = remoteViewModel::setToken,
            onConnect = remoteViewModel::connect,
        )
    }
}

@Composable
private fun PairingScreen(
    endpoint: String,
    token: String,
    connection: ConnectionState,
    error: String?,
    onEndpointChange: (String) -> Unit,
    onTokenChange: (String) -> Unit,
    onConnect: () -> Unit,
) {
    Scaffold(
        topBar = { TopAppBar(title = { Text("Mimi Remote · Android") }) },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                "从 Android 平板安全连接到 Mac 上的 Codex",
                style = MaterialTheme.typography.headlineSmall,
            )
            Text(
                "请先在 Mac 上运行 agentd up，然后输入 Tailscale 地址和访问码。公网 HTTP 会被拒绝。",
                style = MaterialTheme.typography.bodyMedium,
            )
            OutlinedTextField(
                value = endpoint,
                onValueChange = onEndpointChange,
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Mac Endpoint") },
                placeholder = { Text("http://100.x.x.x:8787") },
                singleLine = true,
            )
            OutlinedTextField(
                value = token,
                onValueChange = onTokenChange,
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Agentd 访问码") },
                singleLine = true,
            )
            Button(
                onClick = onConnect,
                enabled = connection != ConnectionState.Connecting,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(if (connection == ConnectionState.Connecting) "连接中…" else "连接 Mac")
            }
            error?.let {
                Text(it, color = MaterialTheme.colorScheme.error)
            }
        }
    }
}

@Composable
private fun WorkbenchScreen(remoteViewModel: RemoteViewModel) {
    val state by remoteViewModel.state.collectAsStateWithLifecycle()
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Codex 工作台") },
                actions = { Text("已连接", modifier = Modifier.padding(horizontal = 16.dp)) },
            )
        },
    ) { padding ->
        Row(
            modifier = Modifier.fillMaxSize().padding(padding).padding(12.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Card(modifier = Modifier.weight(0.30f).fillMaxSize()) {
                Column(modifier = Modifier.padding(12.dp)) {
                    Text("会话", style = MaterialTheme.typography.titleMedium)
                    HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
                    LazyColumn {
                        items(state.sessions, key = { it.id }) { session ->
                            Button(
                                onClick = { remoteViewModel.selectSession(session.id) },
                                modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
                            ) {
                                Text(session.title ?: session.id, maxLines = 1)
                            }
                        }
                    }
                }
            }
            Card(modifier = Modifier.weight(0.70f).fillMaxSize()) {
                Column(modifier = Modifier.fillMaxSize().padding(12.dp)) {
                    Text(
                        state.selectedSessionId?.let { "会话 $it" } ?: "请选择会话",
                        style = MaterialTheme.typography.titleMedium,
                    )
                    HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
                    LazyColumn(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        items(state.messages) { message ->
                            Text(
                                "${message.role}: ${message.text}",
                                fontFamily = if (message.role == "assistant") FontFamily.Default else FontFamily.Monospace,
                            )
                        }
                    }
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        OutlinedTextField(
                            value = state.draft,
                            onValueChange = remoteViewModel::setDraft,
                            modifier = Modifier.weight(1f),
                            placeholder = { Text("输入消息…") },
                        )
                        Button(onClick = remoteViewModel::sendMessage) {
                            Text("发送")
                        }
                    }
                    state.error?.let {
                        Text(it, color = MaterialTheme.colorScheme.error)
                    }
                }
            }
        }
    }
}
