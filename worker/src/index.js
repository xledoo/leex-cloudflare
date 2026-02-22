/**
 * CF IP Optimizer Worker
 * Provides API endpoints for reading IP optimization results
 */

// Default configuration
const DEFAULT_CONFIG = {
  interval: 3600,
  testCount: 1000,
  downloadCount: 50,
  latencyMax: 200,
  downloadMin: 5,
  ports: [443],
  ipVersion: "both"
};

// CORS headers
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
  "Content-Type": "application/json; charset=utf-8"
};

// Text response headers
const textHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Content-Type": "text/plain; charset=utf-8"
};

/**
 * Handle OPTIONS request for CORS
 */
function handleOptions() {
  return new Response(null, {
    status: 204,
    headers: corsHeaders
  });
}

/**
 * Return JSON response
 */
function jsonResponse(data, status = 200) {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: corsHeaders
  });
}

/**
 * Return text response
 */
function textResponse(text, status = 200) {
  return new Response(text, {
    status,
    headers: textHeaders
  });
}

/**
 * GET /api/ips - Return IPs as plain text (ip:port per line)
 */
async function getIpsText(KV) {
  const result = await KV.get("result", { type: "json" });

  if (!result || !result.ips || result.ips.length === 0) {
    return textResponse("# No optimized IPs available yet\n");
  }

  const lines = result.ips.map(ip => `${ip.ip}:${ip.port}`);
  return textResponse(lines.join("\n"));
}

/**
 * GET /api/ips/json - Return full result as JSON
 */
async function getIpsJson(KV) {
  const result = await KV.get("result", { type: "json" });

  if (!result) {
    return jsonResponse({
      lastUpdated: null,
      ips: [],
      error: "No results available yet. Wait for the optimizer to run."
    });
  }

  return jsonResponse(result);
}

/**
 * GET /api/ips/conf - Return configuration
 */
async function getConfig(KV) {
  const config = await KV.get("config", { type: "json" });

  if (!config) {
    return jsonResponse(DEFAULT_CONFIG);
  }

  // Merge with defaults for any missing fields
  return jsonResponse({
    ...DEFAULT_CONFIG,
    ...config
  });
}

/**
 * Main request handler
 */
async function handleRequest(request, env) {
  const url = new URL(request.url);
  const path = url.pathname;

  // Handle CORS preflight
  if (request.method === "OPTIONS") {
    return handleOptions();
  }

  // Route requests
  if (request.method === "GET") {
    switch (path) {
      case "/api/ips":
        return getIpsText(env.KV);

      case "/api/ips/json":
        return getIpsJson(env.KV);

      case "/api/ips/conf":
        return getConfig(env.KV);

      case "/":
      case "/health":
        return jsonResponse({
          name: "CF IP Optimizer API",
          version: "1.0.0",
          endpoints: [
            "GET /api/ips - Plain text IP list (ip:port per line)",
            "GET /api/ips/json - Full result with latency and speed",
            "GET /api/ips/conf - Current optimization configuration"
          ]
        });

      default:
        return jsonResponse({ error: "Not found" }, 404);
    }
  }

  return jsonResponse({ error: "Method not allowed" }, 405);
}

// Export for Cloudflare Workers
export default {
  async fetch(request, env, ctx) {
    return handleRequest(request, env);
  }
};
