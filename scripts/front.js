// npm run front  ->  http://localhost:3000
// Despliega CTL-Lote en la red de Hardhat y sirve el front. El front habla con la
// blockchain a través de /rpc, así que no hace falta MetaMask ni un nodo aparte.
const http = require("http");
const fs = require("fs");
const path = require("path");
const hre = require("hardhat");
const { desplegar } = require("./roles");

const NOMBRES = {
  comite: "Comité", productor: "Productor", beneficio: "Beneficio", qGrader: "Q Grader",
  transportista: "Transportista", tostador: "Tostador", cafeteria: "Cafetería",
  auditor: "Auditor", gateway: "Gateway IoT", intruso: "Intruso (sin rol)",
};

const raiz = path.join(__dirname, "..");
const ARCHIVOS = {
  "/": [path.join(raiz, "frontend", "index.html"), "text/html; charset=utf-8"],
  "/ethers.js": [path.join(raiz, "node_modules", "ethers", "dist", "ethers.umd.min.js"), "text/javascript"],
};

async function rpc({ id, method, params }) {
  try {
    return { jsonrpc: "2.0", id, result: await hre.network.provider.request({ method, params }) };
  } catch (e) {
    return { jsonrpc: "2.0", id, error: { code: e.code ?? -32603, message: e.message, data: e.data } };
  }
}

async function main() {
  const { ctl, ...cuentas } = await desplegar(hre.ethers);
  const address = await ctl.getAddress();
  const config = JSON.stringify({
    address,
    abi: (await hre.artifacts.readArtifact("CTLLote")).abi,
    cuentas: Object.entries(cuentas).map(([k, s]) => ({ nombre: NOMBRES[k], address: s.address })),
  });

  const puerto = process.env.PORT || 3000;
  http.createServer(async (req, res) => {
    if (req.method === "POST" && req.url === "/rpc") {
      let body = "";
      for await (const chunk of req) body += chunk;
      const pedido = JSON.parse(body);
      const respuesta = Array.isArray(pedido) ? await Promise.all(pedido.map(rpc)) : await rpc(pedido);
      res.writeHead(200, { "Content-Type": "application/json" });
      return res.end(JSON.stringify(respuesta));
    }
    if (req.url === "/config.json") {
      res.writeHead(200, { "Content-Type": "application/json" });
      return res.end(config);
    }
    const archivo = ARCHIVOS[req.url];
    if (!archivo) return res.writeHead(404).end();
    res.writeHead(200, { "Content-Type": archivo[1] });
    fs.createReadStream(archivo[0]).pipe(res);
  }).listen(puerto, () => console.log(`CTL-Lote desplegado en ${address} · front en http://localhost:${puerto}`));
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
