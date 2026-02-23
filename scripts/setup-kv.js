#!/usr/bin/env node
/**
 * KV Setup Script for CF IP Optimizer
 *
 * Usage:
 *   node setup-kv.js --method=wrangler
 *   node setup-kv.js --method=api --account-id=xxx --api-token=xxx
 */

const readline = require('readline');

// Parse command line arguments
const args = process.argv.slice(2).reduce((acc, arg) => {
  const [key, value] = arg.replace('--', '').split('=');
  acc[key] = value;
  return acc;
}, {});

// Default configuration
const DEFAULT_CLIENT_ID = 'home-nas';
const DEFAULT_TOKEN = 'YOUR_SECRET_TOKEN_HERE';

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout
});

function question(prompt) {
  return new Promise((resolve) => {
    rl.question(prompt, resolve);
  });
}

async function setupWithWrangler(clientId, token, config) {
  const { execSync } = require('child_process');

  console.log('\n📦 Using Wrangler to setup KV...\n');

  try {
    // Set instance token
    const instanceKey = `instance:${clientId}`;
    const instanceValue = JSON.stringify({ token: token });

    console.log(`Setting ${instanceKey}...`);
    execSync(
      `wrangler kv:key put --binding=KV "${instanceKey}" '${instanceValue}'`,
      { stdio: 'inherit', cwd: __dirname + '/../worker' }
    );

    // Set config (optional)
    if (config) {
      const configKey = `config:${clientId}`;
      console.log(`Setting ${configKey}...`);
      execSync(
        `wrangler kv:key put --binding=KV "${configKey}" '${config}'`,
        { stdio: 'inherit', cwd: __dirname + '/../worker' }
      );
    }

    console.log('\n✅ KV setup completed successfully!');
    console.log('\nNext steps:');
    console.log(`1. Update docker/.env:`);
    console.log(`   CLIENT_ID=${clientId}`);
    console.log(`   TOKEN=${token}`);
    console.log(`   WORKER_URL=https://your-worker.workers.dev`);
    console.log(`2. Start optimizer: docker-compose up -d`);

  } catch (error) {
    console.error('\n❌ Error setting up KV:', error.message);
    console.error('Make sure wrangler is installed and you are logged in.');
    console.error('Run: wrangler login');
    process.exit(1);
  }
}

async function setupWithAPI(accountId, apiToken, clientId, token, config) {
  const https = require('https');

  const kvNamespaceId = '67cbf15db6d74ec8a7674030fd348720';

  console.log('\n🌐 Using Cloudflare API to setup KV...\n');

  function putKV(key, value) {
    return new Promise((resolve, reject) => {
      const options = {
        hostname: 'api.cloudflare.com',
        port: 443,
        path: `/client/v4/accounts/${accountId}/storage/kv/namespaces/${kvNamespaceId}/values/${key}`,
        method: 'PUT',
        headers: {
          'Authorization': `Bearer ${apiToken}`,
          'Content-Type': 'application/json'
        }
      };

      const req = https.request(options, (res) => {
        let data = '';
        res.on('data', chunk => data += chunk);
        res.on('end', () => {
          if (res.statusCode === 200) {
            resolve(data);
          } else {
            reject(new Error(`API Error: ${res.statusCode} - ${data}`));
          }
        });
      });

      req.on('error', reject);
      req.write(value);
      req.end();
    });
  }

  try {
    // Set instance token
    const instanceKey = `instance:${clientId}`;
    const instanceValue = JSON.stringify({ token: token });

    console.log(`Setting ${instanceKey}...`);
    await putKV(instanceKey, instanceValue);

    // Set config (optional)
    if (config) {
      const configKey = `config:${clientId}`;
      console.log(`Setting ${configKey}...`);
      await putKV(configKey, config);
    }

    console.log('\n✅ KV setup completed successfully!');
    console.log('\nNext steps:');
    console.log(`1. Update docker/.env:`);
    console.log(`   CLIENT_ID=${clientId}`);
    console.log(`   TOKEN=${token}`);
    console.log(`   WORKER_URL=https://your-worker.workers.dev`);
    console.log(`2. Start optimizer: docker-compose up -d`);

  } catch (error) {
    console.error('\n❌ Error setting up KV:', error.message);
    process.exit(1);
  }
}

async function main() {
  console.log('🚀 CF IP Optimizer - KV Setup\n');

  const method = args.method || await question('Choose method (wrangler/api): ');
  const clientId = args['client-id'] || await question(`Client ID [${DEFAULT_CLIENT_ID}]: `) || DEFAULT_CLIENT_ID;
  const token = args.token || await question(`Token [${DEFAULT_TOKEN}]: `) || DEFAULT_TOKEN;

  // Optional config
  const setConfig = await question('Set custom config? (y/N): ');
  let config = null;
  if (setConfig.toLowerCase() === 'y') {
    config = JSON.stringify({
      interval: 3600,
      testCount: 1000,
      downloadCount: 50,
      latencyMax: 200,
      downloadMin: 5,
      ports: [443],
      ipVersion: "both"
    });
  }

  rl.close();

  if (method === 'wrangler') {
    await setupWithWrangler(clientId, token, config);
  } else if (method === 'api') {
    const accountId = args['account-id'] || await question('Cloudflare Account ID: ');
    const apiToken = args['api-token'] || await question('Cloudflare API Token: ');
    await setupWithAPI(accountId, apiToken, clientId, token, config);
  } else {
    console.error('❌ Invalid method. Use "wrangler" or "api"');
    process.exit(1);
  }
}

main().catch(console.error);
