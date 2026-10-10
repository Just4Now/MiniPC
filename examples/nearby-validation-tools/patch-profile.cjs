const fs=require('node:fs');
const [certificate,profile]=process.argv.slice(2);
if(!certificate||!profile){console.error('Usage: node patch-profile.cjs <certificate.pem> <profile.json>');process.exit(2);}
const value=JSON.parse(fs.readFileSync(profile,'utf8'));
value['bundle-info']['development-certificate']=fs.readFileSync(certificate,'utf8').trim()+'\n';
fs.writeFileSync(profile,JSON.stringify(value,null,2)+'\n');
