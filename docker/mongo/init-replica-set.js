const config = {
  _id: "rs0",
  members: [
    { _id: 0, host: "mongo1:27017", priority: 2 },
    { _id: 1, host: "mongo2:27017" },
    { _id: 2, host: "mongo3:27017" },
  ],
};

function sameMembers(currentConfig, desiredConfig) {
  const currentHosts = currentConfig.members.map((member) => member.host).sort();
  const desiredHosts = desiredConfig.members.map((member) => member.host).sort();
  return JSON.stringify(currentHosts) === JSON.stringify(desiredHosts);
}

function reconcileMembers(desiredConfig) {
  const desiredHosts = desiredConfig.members.map((member) => member.host);
  let currentConfig = rs.conf();
  let currentHosts = currentConfig.members.map((member) => member.host);

  for (const host of currentHosts) {
    if (!desiredHosts.includes(host)) {
      print(`Removendo membro ${host}...`);
      rs.remove(host);
      sleep(3000);
    }
  }

  currentConfig = rs.conf();
  currentHosts = currentConfig.members.map((member) => member.host);

  for (const member of desiredConfig.members) {
    if (!currentHosts.includes(member.host)) {
      print(`Adicionando membro ${member.host}...`);
      rs.add(member);
      sleep(3000);
    }
  }
}

let currentConfig = null;

try {
  currentConfig = rs.conf();
} catch (error) {
  print("Inicializando replica set rs0...");
  rs.initiate(config);
}

if (currentConfig !== null) {
  if (sameMembers(currentConfig, config)) {
    print(`Replica set ${currentConfig._id} ja esta configurado com 3 nodes.`);
  } else {
    print("Reconfigurando replica set para 3 nodes...");
    reconcileMembers(config);
  }
}

for (let attempt = 0; attempt < 60; attempt += 1) {
  const hello = db.hello();
  if (hello.isWritablePrimary) {
    print(`Replica set pronto. Primario: ${hello.primary}`);
    quit(0);
  }
  sleep(1000);
}

print("Replica set nao ficou pronto dentro do tempo esperado.");
quit(1);
