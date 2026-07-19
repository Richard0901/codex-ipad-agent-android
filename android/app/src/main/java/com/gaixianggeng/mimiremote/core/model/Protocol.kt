package com.gaixianggeng.mimiremote.core.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

@Serializable
data class JsonRpcRequest(
    val id: Long,
    val method: String,
    val params: JsonElement? = null,
)

@Serializable
data class JsonRpcResponse(
    val id: JsonElement,
    val result: JsonElement? = null,
    val error: JsonRpcError? = null,
)

@Serializable
data class JsonRpcNotification(
    val method: String,
    val params: JsonElement? = null,
)

@Serializable
data class JsonRpcServerRequest(
    val id: JsonElement,
    val method: String,
    val params: JsonElement? = null,
)

@Serializable
data class JsonRpcError(
    val code: Int,
    val message: String,
    val data: JsonElement? = null,
)

@Serializable
data class Project(
    val id: String? = null,
    val path: String,
    val name: String? = null,
)

@Serializable
data class Session(
    val id: String,
    val title: String? = null,
    val cwd: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
    val status: String? = null,
)

@Serializable
data class AppServerConfig(
    @SerialName("gateway_ws_url") val gatewayWsUrl: String,
    val projects: List<Project> = emptyList(),
    val runtime: RuntimeMetadata? = null,
)

@Serializable
data class RuntimeMetadata(
    val type: String? = null,
    val transport: String? = null,
    val running: Boolean = false,
    @SerialName("gateway_available") val gatewayAvailable: Boolean = false,
)

sealed interface RemoteEvent {
    data class AssistantDelta(val threadId: String?, val text: String) : RemoteEvent
    data class TurnCompleted(val threadId: String?) : RemoteEvent
    data class ApprovalRequired(val request: JsonRpcServerRequest) : RemoteEvent
    data class ServerNotification(val notification: JsonRpcNotification) : RemoteEvent
}
