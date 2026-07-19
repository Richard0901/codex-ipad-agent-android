package com.gaixianggeng.mimiremote.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.gaixianggeng.mimiremote.core.model.Project
import com.gaixianggeng.mimiremote.core.model.Session
import com.gaixianggeng.mimiremote.core.network.AgentGatewayClient
import com.gaixianggeng.mimiremote.core.network.EndpointPolicy
import com.gaixianggeng.mimiremote.core.network.GatewayEvent
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.jsonObject

enum class ConnectionState { Disconnected, Connecting, Connected, Failed }

data class ChatLine(val role: String, val text: String)

data class RemoteUiState(
    val endpoint: String = "",
    val token: String = "",
    val connection: ConnectionState = ConnectionState.Disconnected,
    val error: String? = null,
    val projects: List<Project> = emptyList(),
    val selectedProjectPath: String? = null,
    val sessions: List<Session> = emptyList(),
    val selectedSessionId: String? = null,
    val messages: List<ChatLine> = emptyList(),
    val draft: String = "",
)

class RemoteViewModel : ViewModel() {
    private val json = Json { ignoreUnknownKeys = true }
    private val _state = MutableStateFlow(RemoteUiState())
    val state: StateFlow<RemoteUiState> = _state.asStateFlow()
    private var client: AgentGatewayClient? = null
    private var connectionJob: Job? = null
    private var nextRpcId = 100L

    fun setEndpoint(value: String) {
        _state.value = _state.value.copy(endpoint = value, error = null)
    }

    fun setToken(value: String) {
        _state.value = _state.value.copy(token = value, error = null)
    }

    fun setDraft(value: String) {
        _state.value = _state.value.copy(draft = value)
    }

    fun connect() {
        connectionJob?.cancel()
        val endpoint = runCatching { EndpointPolicy.requireAllowed(_state.value.endpoint) }
            .getOrElse {
                _state.value = _state.value.copy(connection = ConnectionState.Failed, error = it.message)
                return
            }
        if (_state.value.token.isBlank()) {
            _state.value = _state.value.copy(connection = ConnectionState.Failed, error = "请输入配对访问码")
            return
        }

        val gateway = AgentGatewayClient(endpoint, _state.value.token)
        client = gateway
        _state.value = _state.value.copy(
            endpoint = endpoint,
            connection = ConnectionState.Connecting,
            error = null,
        )
        connectionJob = viewModelScope.launch {
            gateway.events().collect { event ->
                when (event) {
                    GatewayEvent.Opened -> {
                        _state.value = _state.value.copy(connection = ConnectionState.Connected)
                        runCatching { gateway.loadConfig() }
                            .onSuccess { config ->
                                val project = config.projects.firstOrNull()
                                _state.value = _state.value.copy(
                                    projects = config.projects,
                                    selectedProjectPath = project?.path,
                                )
                                if (project != null) {
                                    request(
                                        "thread/list",
                                        JsonObject(mapOf("cwd" to JsonPrimitive(project.path))),
                                    )
                                }
                            }
                            .onFailure {
                                _state.value = _state.value.copy(
                                    connection = ConnectionState.Failed,
                                    error = it.message,
                                )
                            }
                    }
                    is GatewayEvent.Message -> handleMessage(event.payload)
                    is GatewayEvent.Failed -> _state.value = _state.value.copy(
                        connection = ConnectionState.Failed,
                        error = event.message,
                    )
                    is GatewayEvent.Closed -> if (_state.value.connection != ConnectionState.Failed) {
                        _state.value = _state.value.copy(connection = ConnectionState.Disconnected)
                    }
                }
            }
        }
    }

    fun selectSession(id: String) {
        _state.value = _state.value.copy(selectedSessionId = id)
        val params = mutableMapOf<String, kotlinx.serialization.json.JsonElement>(
            "threadId" to JsonPrimitive(id),
        )
        _state.value.selectedProjectPath?.let { params["cwd"] = JsonPrimitive(it) }
        request("thread/read", JsonObject(params))
    }

    fun sendMessage() {
        val current = _state.value
        val text = current.draft.trim()
        if (text.isEmpty()) return
        val sessionId = current.selectedSessionId
        if (sessionId == null) {
            _state.value = current.copy(error = "请先选择或创建会话")
            return
        }
        _state.value = current.copy(
            draft = "",
            messages = current.messages + ChatLine("user", text),
        )
        request(
            "turn/start",
            JsonObject(
                buildMap {
                    put("threadId", JsonPrimitive(sessionId))
                    put("input", kotlinx.serialization.json.buildJsonArray {
                        add(JsonObject(mapOf("type" to JsonPrimitive("text"), "text" to JsonPrimitive(text))))
                    })
                    put("approvalPolicy", JsonPrimitive("on-request"))
                    put("approvalsReviewer", JsonPrimitive("user"))
                    put("sandboxPolicy", JsonObject(
                        mapOf(
                            "type" to JsonPrimitive("workspaceWrite"),
                            "networkAccess" to JsonPrimitive(false),
                        ),
                    ))
                    current.selectedProjectPath?.let { put("cwd", JsonPrimitive(it)) }
                },
            ),
        )
    }

    private fun request(method: String, params: JsonObject) {
        runCatching { client?.send(method, params) }
            .onFailure { _state.value = _state.value.copy(error = it.message) }
    }

    private fun handleMessage(payload: kotlinx.serialization.json.JsonElement) {
        val objectPayload = payload as? JsonObject ?: return
        val method = objectPayload["method"]?.jsonPrimitive?.contentOrNull
        if (method != null) {
            val params = objectPayload["params"] as? JsonObject
            when {
                method.contains("approval", ignoreCase = true) -> {
                    _state.value = _state.value.copy(error = "Codex 请求审批，请在当前版本中确认后继续")
                }
                method.contains("delta", ignoreCase = true) -> {
                    val text = params?.values?.firstOrNull { it is JsonPrimitive }?.jsonPrimitive?.contentOrNull
                    if (!text.isNullOrBlank()) {
                        _state.value = _state.value.copy(messages = appendAssistant(text))
                    }
                }
                method.contains("completed", ignoreCase = true) -> Unit
            }
            return
        }
        val result = objectPayload["result"] as? JsonObject ?: return
        val threads = result["data"]?.let { data ->
            if (data is JsonObject) data["items"] ?: data["threads"] ?: data else data
        } ?: result["threads"] ?: return
        val decoded = runCatching {
            json.decodeFromJsonElement<List<Session>>(threads)
        }.getOrNull()
        if (decoded != null) _state.value = _state.value.copy(sessions = decoded)
    }

    private fun appendAssistant(text: String): List<ChatLine> {
        val messages = _state.value.messages.toMutableList()
        val last = messages.lastOrNull()
        if (last?.role == "assistant") messages[messages.lastIndex] = last.copy(text = last.text + text)
        else messages += ChatLine("assistant", text)
        return messages
    }

    override fun onCleared() {
        connectionJob?.cancel()
        client = null
        super.onCleared()
    }
}
