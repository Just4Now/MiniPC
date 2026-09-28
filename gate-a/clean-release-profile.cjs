const fs = require('fs');
const j = JSON.parse(fs.readFileSync('D:/MINIPC/tools/signing/release-profile.json', 'utf8'));
function cleanPem(pem) {
  const m = String(pem).match(/-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----/);
  if (!m) throw new Error('no pem');
  const body = m[1].replace(/\s/g, '');
  const lines = body.match(/.{1,64}/g).join('\n');
  return '-----BEGIN CERTIFICATE-----\n' + lines + '\n-----END CERTIFICATE-----\n';
}
j['bundle-info']['distribution-certificate'] = cleanPem(j['bundle-info']['distribution-certificate']);
fs.writeFileSync('D:/Agent-MiniPC/gate-a/compute-release-profile.json', JSON.stringify(j));
console.log('type', j.type, 'bundle', j['bundle-info']['bundle-name']);
