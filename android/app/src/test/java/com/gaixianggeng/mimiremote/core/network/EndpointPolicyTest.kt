package com.gaixianggeng.mimiremote.core.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class EndpointPolicyTest {
    @Test
    fun `private tailscale http gets default port`() {
        val result = EndpointPolicy.assess("100.64.1.2")
        assertEquals(
            EndpointAssessment.Allowed("http://100.64.1.2:8787", secure = false),
            result,
        )
    }

    @Test
    fun `public http is blocked`() {
        val result = EndpointPolicy.assess("http://example.com:8787")
        assertTrue(result is EndpointAssessment.BlockedPublicHttp)
    }

    @Test
    fun `https domain is allowed`() {
        val result = EndpointPolicy.assess("https://remote.example.com")
        assertEquals(
            EndpointAssessment.Allowed("https://remote.example.com", secure = true),
            result,
        )
    }

    @Test
    fun `path and query are rejected`() {
        assertTrue(EndpointPolicy.assess("http://100.64.1.2/api").isInvalid())
        assertTrue(EndpointPolicy.assess("http://100.64.1.2?token=secret").isInvalid())
    }

    private fun EndpointAssessment.isInvalid() = this is EndpointAssessment.Invalid
}
