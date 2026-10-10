const fs = require('fs');
const crypto = require('crypto');
function certs(path) {
  const text = fs.readFileSync(path, 'utf8');
  const re = /-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----/g;
  let m, i = 0;
  console.log('====', path);
  while ((m = re.exec(text)) !== null) {
    const der = Buffer.from(m[1].replace(/\s/g, ''), 'base64');
    console.log(i++, crypto.createHash('sha256').update(der).digest('hex'), 'len', der.length);
  }
}
const files = [
  'D:/MINIPC/tools/signing/app.cer',
  'D:/MINIPC/tools/signing/app-chain-fmt.cer',
  'D:/MINIPC/tools/signing/app-chain.cer',
  'D:/MINIPC/tools/signing/app-clean.cer',
  'D:/MINIPC/tools/signing/app-issued-leaf.cer',
  'D:/MINIPC/tools/signing/app-issued-chain.cer',
  'D:/MINIPC/tools/signing/rel.cer'
];
for (const p of files) certs(p);
console.log('installed 284584f15151aece13602af4620cab29b5141e1ad42c0b95f692a4d87b245628');
