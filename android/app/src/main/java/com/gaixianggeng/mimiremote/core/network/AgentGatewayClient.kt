package com.gaixianggeng.mimiremote.core.network

import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import com.gaixianggeng.mimiremote.core.model.AppServerConfig
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.concurrent.TimeUnit

class AgentGatewayClient(
    private val endpoint: String,
    private val token: String,
    private val httpClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .pingInterval(45, TimeUnit.SECONDS)
        .build(),
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = false }
    private var requestId = 0L
    @Volatile private var activeSocket: WebSocket? = null

    fun events(): Flow<GatewayEvent> = callbackFlow {
        val wsUrl = endpoint.toHttpUrl().newBuilder()
            .scheme(if (endpoint.startsWith("https")) "wss" else "ws")
            .addPathSegments("api/app-server/ws")
            .build()
        val request = Request.Builder()
            .url(wsUrl)
            .header("Authorization", "Bearer $token")
            .build()
        val socket = httpClient.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                activeSocket = webSocket
                trySend(GatewayEvent.Opened)
                send(webSocket, "initialize", buildJsonObject("clientName" to JsonPrimitive("Mimi Remote Android")))
                send(webSocket, "initialized")
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                val element = runCatching { json.parseToJsonElement(text) }.getOrNull()
                    ?: return@onMessage
                trySend(GatewayEvent.Message(element))
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                activeSocket = null
                trySend(GatewayEvent.Failed(t.message ?: "连接失败"))
                close(t)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                activeSocket = null
                trySend(GatewayEvent.Closed(code, reason))
                close()
            }
        })
        awaitClose {
            activeSocket = null
            socket.close(1000, "screen closed")
        }
    }

    suspend fun loadConfig(): AppServerConfig {
        val request = Request.Builder()
            .url(endpoint.toHttpUrl().newBuilder().addPathSegments("api/app-server/config").build())
            .header("Authorization", "Bearer $token")
            .get()
            .build()
        val response = httpClient.newCall(request).execute()
        response.use {
            if (!it.isSuccessful) error("agentd 返回 HTTP ${it.code}")
            val body = it.body?.string() ?: error("agentd 响应为空")
            return json.decodeFromString<AppServerConfig>(body)
        }
    }

    fun send(method: String, params: JsonElement? = null): Long {
        return send(requireNotNull(activeSocket) { "WebSocket 尚未连接" }, method, params)
    }

    private fun send(socket: WebSocket, method: String, params: JsonElement? = null): Long {
        val id = ++requestId
        val fields = mutableMapOf<String, JsonElement>(
            "id" to JsonPrimitive(id),
            "method" to JsonPrimitive(method),
        )
        if (params != null) fields["params"] = params
        socket.send(json.encodeToString(JsonElement.serializer(), JsonObject(fields)))
        return id
    }

    private fun buildJsonObject(vararg fields: Pair<String, JsonElement>): JsonObject =
        JsonObject(fields.toMap())
}

sealed interface GatewayEvent {
    data object Opened : GatewayEvent
    data class Message(val payload: JsonElement) : GatewayEvent
    data class Failed(val message: String) : GatewayEvent
    data class Closed(val code: Int, val reason: String) : GatewayEvent
}
