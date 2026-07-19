package com.gaixianggeng.mimiremote.core.network

import java.net.URI
import java.util.Locale

sealed interface EndpointAssessment {
    data object Empty : EndpointAssessment
    data class Invalid(val reason: String) : EndpointAssessment
    data class BlockedPublicHttp(val host: String) : EndpointAssessment
    data class Allowed(val endpoint: String, val secure: Boolean) : EndpointAssessment
}

object EndpointPolicy {
    fun assess(raw: String): EndpointAssessment {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return EndpointAssessment.Empty

        val candidate = if ("://" in trimmed) trimmed else "http://$trimmed"
        val uri = runCatching { URI(candidate) }.getOrNull()
            ?: return EndpointAssessment.Invalid("地址格式无效")
        val scheme = uri.scheme?.lowercase(Locale.US)
            ?: return EndpointAssessment.Invalid("缺少协议")
        val host = uri.host?.lowercase(Locale.US)
            ?: return EndpointAssessment.Invalid("缺少主机名")
        if (scheme != "http" && scheme != "https") {
            return EndpointAssessment.Invalid("仅支持 HTTP 或 HTTPS")
        }
        if (uri.path.isNotEmpty() && uri.path != "/") {
            return EndpointAssessment.Invalid("地址不能包含路径")
        }
        if (uri.query != null || uri.fragment != null || uri.userInfo != null) {
            return EndpointAssessment.Invalid("地址不能包含查询、片段或用户信息")
        }
        if (scheme == "http" && !isPrivateHost(host)) {
            return EndpointAssessment.BlockedPublicHttp(host)
        }

        val port = if (uri.port == -1 && scheme == "http") 8787 else uri.port
        val normalized = URI(scheme, null, host, port, null, null, null).toString()
            .removeSuffix("/")
        return EndpointAssessment.Allowed(normalized, secure = scheme == "https")
    }

    fun requireAllowed(raw: String): String = when (val assessment = assess(raw)) {
        is EndpointAssessment.Allowed -> assessment.endpoint
        EndpointAssessment.Empty -> error("请输入 Mac 的连接地址")
        is EndpointAssessment.Invalid -> error(assessment.reason)
        is EndpointAssessment.BlockedPublicHttp ->
            error("已阻止公网 HTTP 地址：${assessment.host}。请使用 Tailscale 或 HTTPS")
    }

    private fun isPrivateHost(host: String): Boolean {
        if (host == "localhost" || host == "::1" || host.endsWith(".local") || host.endsWith(".ts.net")) {
            return true
        }
        val ipv4 = host.split('.').mapNotNull { it.toIntOrNull() }
        if (ipv4.size != 4) return false
        return ipv4[0] == 10 ||
            (ipv4[0] == 172 && ipv4[1] in 16..31) ||
            (ipv4[0] == 192 && ipv4[1] == 168) ||
            (ipv4[0] == 100 && ipv4[1] in 64..127)
    }
}
