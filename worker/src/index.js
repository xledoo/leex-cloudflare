/**
 * CF IP Optimizer Worker
 * Multi-instance support with client_id isolation
 */

const DEFAULT_CONFIG = {
  interval: 3600,
  testCount: 500,
  downloadCount: 100,
  latencyMax: 200,
  downloadMin: 10,
  ports: [443],
  ipVersion: "both"
};

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
  "Content-Type": "application/json; charset=utf-8"
};

const textHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Content-Type": "text/plain; charset=utf-8"
};

function handleOptions() {
  return new Response(null, {
    status: 204,
    headers: corsHeaders
  });
}

function jsonResponse(data, status = 200) {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: corsHeaders
  });
}

function textResponse(text, status = 200) {
  return new Response(text, {
    status,
    headers: textHeaders
  });
}

function getInstanceKey(clientId) {
  return `instance:${clientId}`;
}

function getResultKey(clientId) {
  return `result:${clientId}`;
}

function getConfigKey(clientId) {
  return `config:${clientId}`;
}

function getSubmitIpsToKey(clientId) {
  return `submit_ips_to:${clientId}`;
}

async function getSubmitIpsToUrl(KV, clientId) {
  const key = getSubmitIpsToKey(clientId);
  const url = await KV.get(key);
  return url || null;
}

async function submitIpsToApi(ips, submitUrl, clientId) {
  if (!submitUrl || !ips || ips.length === 0) {
    return { success: false, reason: "No URL or IPs" };
  }

  const payload = ips.map(ip => ({
    ip: ip.ip,
    port: ip.port || 443,
    name: ip.name || ip.remark || `优选-${ip.ip}`
  }));

  try {
    const response = await fetch(`${submitUrl}/api/preferred-ips`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify(payload)
    });

    if (response.ok) {
      const result = await response.json();
      return { success: true, count: payload.length, response: result };
    } else {
      const errorText = await response.text();
      return { success: false, status: response.status, error: errorText };
    }
  } catch (e) {
    return { success: false, error: e.message };
  }
}

async function validateToken(KV, clientId, token) {
  if (!clientId || !token) {
    return { valid: false, error: "Missing client_id or token" };
  }

  const instanceKey = getInstanceKey(clientId);
  const instance = await KV.get(instanceKey, { type: "json" });

  if (!instance) {
    return { valid: false, error: "Instance not registered" };
  }

  if (instance.token !== token) {
    return { valid: false, error: "Invalid token" };
  }

  return { valid: true };
}

async function handleReport(request, env) {
  try {
    const body = await request.json();
    const { client_id, token, data } = body;

    if (!client_id || !token) {
      return jsonResponse({ error: "Missing client_id or token" }, 400);
    }

    const validation = await validateToken(env.KV, client_id, token);
    if (!validation.valid) {
      return jsonResponse({ error: validation.error }, 401);
    }

    if (!data) {
      return jsonResponse({ error: "Missing data" }, 400);
    }

    const resultKey = getResultKey(client_id);
    await env.KV.put(resultKey, JSON.stringify({
      ...data,
      clientId: client_id,
      lastUpdated: new Date().toISOString()
    }));

    const instanceKey = getInstanceKey(client_id);
    const instance = await env.KV.get(instanceKey, { type: "json" }) || {};
    await env.KV.put(instanceKey, JSON.stringify({
      ...instance,
      lastSeen: new Date().toISOString()
    }));

    let submitResult = null;
    if (data.ips && data.ips.length > 0) {
      const submitUrl = await getSubmitIpsToUrl(env.KV, client_id);
      if (submitUrl) {
        submitResult = await submitIpsToApi(data.ips, submitUrl, client_id);
      }
    }

    const response = { success: true, message: "Results uploaded" };
    if (submitResult) {
      response.submitted = submitResult;
    }

    return jsonResponse(response);
  } catch (e) {
    return jsonResponse({ error: "Invalid request body" }, 400);
  }
}

async function getIpsText(KV, clientId) {
  if (!clientId) {
    return textResponse("# Error: client_id parameter required\n", 400);
  }

  const resultKey = getResultKey(clientId);
  const result = await KV.get(resultKey, { type: "json" });

  if (!result || !result.ips || result.ips.length === 0) {
    return textResponse(`# No optimized IPs available for instance: ${clientId}\n`);
  }

  const lines = result.ips.map(ip => `${ip.ip}:${ip.port}`);
  return textResponse(lines.join("\n"));
}

async function getIpsJson(KV, clientId) {
  if (!clientId) {
    return jsonResponse({ error: "client_id parameter required" }, 400);
  }

  const resultKey = getResultKey(clientId);
  const result = await KV.get(resultKey, { type: "json" });

  if (!result) {
    return jsonResponse({
      clientId: clientId,
      lastUpdated: null,
      ips: [],
      error: `No results available for instance: ${clientId}`
    });
  }

  return jsonResponse(result);
}

async function getConfig(KV, clientId) {
  if (!clientId) {
    return jsonResponse({ error: "client_id parameter required" }, 400);
  }

  const configKey = getConfigKey(clientId);
  const config = await KV.get(configKey, { type: "json" });

  if (!config) {
    return jsonResponse(DEFAULT_CONFIG);
  }

  return jsonResponse({ ...DEFAULT_CONFIG, ...config });
}

async function getSubmitConfig(KV, clientId) {
  if (!clientId) {
    return jsonResponse({ error: "client_id parameter required" }, 400);
  }

  const submitUrl = await getSubmitIpsToUrl(KV, clientId);
  return jsonResponse({
    client_id: clientId,
    submit_ips_to: submitUrl || ""
  });
}

async function setSubmitConfig(KV, clientId, submitUrl) {
  if (!clientId) {
    return jsonResponse({ error: "client_id parameter required" }, 400);
  }

  const key = getSubmitIpsToKey(clientId);
  if (submitUrl && submitUrl.trim()) {
    await KV.put(key, submitUrl.trim());
    return jsonResponse({ success: true, message: "submit_ips_to configured", submit_ips_to: submitUrl.trim() });
  } else {
    await KV.delete(key);
    return jsonResponse({ success: true, message: "submit_ips_to cleared" });
  }
}

async function handleRequest(request, env) {
  const url = new URL(request.url);
  const path = url.pathname;
  const clientId = url.searchParams.get("client_id");

  if (request.method === "OPTIONS") {
    return handleOptions();
  }

  if (request.method === "POST" && path === "/api/report") {
    return handleReport(request, env);
  }

  if (request.method === "POST" && path === "/api/submit-to") {
    try {
      const body = await request.json();
      return setSubmitConfig(env.KV, body.client_id, body.submit_ips_to);
    } catch (e) {
      return jsonResponse({ error: "Invalid request body" }, 400);
    }
  }

  if (request.method === "GET") {
    switch (path) {
      case "/api/ips":
        return getIpsText(env.KV, clientId);

      case "/api/ips/json":
        return getIpsJson(env.KV, clientId);

      case "/api/ips/conf":
        return getConfig(env.KV, clientId);

      case "/api/submit-to":
        return getSubmitConfig(env.KV, clientId);

      case "/":
      case "/health":
        return jsonResponse({
          name: "CF IP Optimizer API",
          version: "2.1.0",
          endpoints: [
            "POST /api/report - Upload results (requires client_id, token in body)",
            "GET /api/ips?client_id=xxx - Plain text IP list",
            "GET /api/ips/json?client_id=xxx - Full result JSON",
            "GET /api/ips/conf?client_id=xxx - Instance configuration",
            "GET /api/submit-to?client_id=xxx - Get submit_ips_to URL",
            "POST /api/submit-to - Set submit_ips_to URL (body: {client_id, submit_ips_to})"
          ]
        });

      default:
        return jsonResponse({ error: "Not found" }, 404);
    }
  }

  return jsonResponse({ error: "Method not allowed" }, 405);
}

export default {
  async fetch(request, env, ctx) {
    return handleRequest(request, env);
  }
};
