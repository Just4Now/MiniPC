const fs = require('fs');
const leaf = fs.readFileSync('D:/MINIPC/tools/signing/app-issued-leaf.cer', 'utf8').trim();
const j = JSON.parse(fs.readFileSync('D:/MINIPC/tools/signing/profile.json', 'utf8'));
j['bundle-info']['development-certificate'] = leaf + '\n';
fs.writeFileSync('D:/Agent-MiniPC/gate-a/compute-profile.json', JSON.stringify(j, null, 2));
console.log(j['bundle-info']['bundle-name'], j['debug-info']['device-ids'].length);
