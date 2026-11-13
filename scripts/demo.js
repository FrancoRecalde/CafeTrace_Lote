// Demo en vivo: npx hardhat run scripts/demo.js
// (o contra un nodo local: `npx hardhat node` en otra terminal y agregar --network localhost)
const { ethers } = require("hardhat");
const { E, Estado, desplegar } = require("./roles");

const h = (s) => ethers.id(s);
const paso = (t) => console.log(`\n▶ ${t}`);

async function estado(ctl, id) {
  const l = await ctl.consultarLote(id);
  console.log(`  lote ${id}: estado=${Estado[l.estado]} custodio=${l.custodioActual.slice(0, 10)}… pesoVerde=${l.pesoVerdeKg}kg puntaje=${Number(l.puntajeSCA) / 100}`);
}

async function intentar(desc, tx) {
  try {
    await tx();
    console.log(`  ✗ ${desc}: NO fue rechazada`);
  } catch (e) {
    console.log(`  ✓ ${desc}: rechazada -> "${e.reason ?? e.shortMessage ?? e.message}"`);
  }
}

async function main() {
  const { ctl, productor, beneficio, qGrader, transportista, tostador, cafeteria, intruso } = await desplegar(ethers);
  console.log(`CTL-Lote desplegado en ${await ctl.getAddress()}`);

  paso("1. Productor crea el lote");
  const cosecha = (await ethers.provider.getBlock("latest")).timestamp - 3600;
  await ctl.connect(productor).crearLote("Finca La Esperanza", "Huila, Colombia", "Geisha", 1800, 0, cosecha, 1200, 20);
  const id = await ctl.cantidadLotes();
  await estado(ctl, id);

  paso("2. Recorrido válido del DTE");
  const b = ctl.connect(beneficio);
  await b.registrarEtapa(id, E.EnBeneficio, 1500, h("boleta pesaje")); await estado(ctl, id);
  await b.registrarEtapa(id, E.Secado, 0, h("lectura humedad")); await estado(ctl, id);
  await b.registrarEtapa(id, E.Almacenado, 115, h("informe secado")); await estado(ctl, id);
  await b.registrarPesoVerde(id, 1200, 20, h("informe trilla")); await estado(ctl, id);
  await ctl.connect(qGrader).firmarCalificacion(id, 8650, h("ficha de cata")); await estado(ctl, id);
  await b.cambiarCustodia(id, transportista.address, 1200, 20);
  await ctl.connect(transportista).aceptarCustodia(id, 1200, 20); await estado(ctl, id);
  await ctl.connect(transportista).cambiarCustodia(id, tostador.address, 1200, 20);
  await ctl.connect(tostador).aceptarCustodia(id, 1200, 20); await estado(ctl, id);
  await ctl.connect(tostador).registrarEtapa(id, E.Tostado, 0, h("perfil tueste")); await estado(ctl, id);
  await ctl.connect(tostador).registrarEtapa(id, E.Empaquetado, 0, h("empaque")); await estado(ctl, id);
  await ctl.connect(tostador).cambiarCustodia(id, cafeteria.address, 1000, 100);
  await ctl.connect(cafeteria).aceptarCustodia(id, 1000, 100); await estado(ctl, id);

  paso("3. Consulta de datos y evidencias");
  const l = await ctl.consultarLote(id);
  console.log(`  ${l.finca} · ${l.region} · ${l.variedad} · ${l.altitud} m`);
  const niveles = ["Declarado", "VerificadoTercero", "Sensorizado", "Auditado"];
  for (const ev of await ctl.consultarEvidencias(id)) console.log(`  evidencia ${ev.hash.slice(0, 12)}… nivel=${niveles[ev.nivel]}`);

  paso("4. Transición inválida");
  await ctl.connect(productor).crearLote("Finca 2", "Huila", "Caturra", 1600, 0, cosecha, 800, 12);
  const id2 = await ctl.cantidadLotes();
  await intentar("Registrado -> Secado", () => b.registrarEtapa(id2, E.Secado, 0, h("x")));
  await intentar("Calificar sin trillar", () => ctl.connect(qGrader).firmarCalificacion(id2, 8500, h("x")));

  paso("5. Operación sin permisos");
  await intentar("Cuenta sin rol crea lote", () => ctl.connect(intruso).crearLote("F", "R", "V", 1, 0, 0, 1, 1));
  await intentar("Productor firma calificación", () => ctl.connect(productor).firmarCalificacion(id2, 9000, h("x")));
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
