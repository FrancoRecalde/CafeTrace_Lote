const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");
const { E, desplegar } = require("../scripts/roles");

const h = (s) => ethers.id(s); // hash de evidencia de ejemplo

async function crear(ctl, productor) {
  const cosecha = (await time.latest()) - 3600; // cosechado hace 1 h
  await ctl.connect(productor).crearLote("Finca La Esperanza", "Huila, Colombia", "Geisha", 1800, 0, cosecha, 1200, 20);
  return await ctl.cantidadLotes();
}

// Lleva un lote desde Registrado hasta Calificado.
async function hastaCalificado(c, id) {
  await c.ctl.connect(c.beneficio).registrarEtapa(id, E.EnBeneficio, 1500, h("boleta pesaje"));
  await c.ctl.connect(c.beneficio).registrarEtapa(id, E.Secado, 0, h("lectura humedad"));
  await c.ctl.connect(c.beneficio).registrarEtapa(id, E.Almacenado, 115, h("informe secado"));
  await c.ctl.connect(c.beneficio).registrarPesoVerde(id, 1200, 20, h("informe trilla"));
  await c.ctl.connect(c.qGrader).firmarCalificacion(id, 8650, h("ficha de cata"));
}

describe("CTL-Lote", () => {
  let c;
  beforeEach(async () => (c = await desplegar(ethers)));

  it("1. crea el lote con su origen y estado Registrado", async () => {
    const id = await crear(c.ctl, c.productor);
    const l = await c.ctl.consultarLote(id);
    expect(l.estado).to.equal(E.Registrado);
    expect(l.productor).to.equal(c.productor.address);
    expect(l.custodioActual).to.equal(c.productor.address);
    expect(l.variedad).to.equal("Geisha");
  });

  it("2. recorre el DTE completo hasta Entregado", async () => {
    const id = await crear(c.ctl, c.productor);
    await hastaCalificado(c, id);
    const { ctl, beneficio, transportista, tostador, cafeteria } = c;

    await ctl.connect(beneficio).cambiarCustodia(id, transportista.address, 1200, 20);
    await ctl.connect(transportista).aceptarCustodia(id, 1200, 20);
    await ctl.connect(transportista).cambiarCustodia(id, tostador.address, 1200, 20);
    await ctl.connect(tostador).aceptarCustodia(id, 1200, 20);
    await ctl.connect(tostador).registrarEtapa(id, E.Tostado, 0, h("perfil de tueste"));
    await ctl.connect(tostador).registrarEtapa(id, E.Empaquetado, 0, h("empaque"));
    await ctl.connect(tostador).cambiarCustodia(id, cafeteria.address, 1000, 100);
    await expect(ctl.connect(cafeteria).aceptarCustodia(id, 1000, 100))
      .to.emit(ctl, "EtapaRegistrada").withArgs(id, E.Empaquetado, E.Entregado, cafeteria.address);

    expect((await ctl.consultarLote(id)).estado).to.equal(E.Entregado);
    expect(await ctl.consultarHistorialCustodia(id)).to.have.length(3);
  });

  it("3. consulta datos, evidencias y niveles de verificación", async () => {
    const id = await crear(c.ctl, c.productor);
    await hastaCalificado(c, id);
    await c.ctl.connect(c.gateway).registrarEvidencia(id, h("lecturas IoT"), "ipfs://Qm...");
    const l = await c.ctl.consultarLote(id);
    expect(l.puntajeSCA).to.equal(8650);
    expect(l.pesoVerdeKg).to.equal(1200);
    expect(l.qGrader).to.equal(c.qGrader.address);
    const ev = await c.ctl.consultarEvidencias(id);
    expect(ev.at(-1).nivel).to.equal(2); // Sensorizado
    expect(ev[3].nivel).to.equal(1); // peso verde: VerificadoTercero
  });

  describe("4. rechaza transiciones inválidas", () => {
    it("no puede saltar de Registrado a Secado", async () => {
      const id = await crear(c.ctl, c.productor);
      await expect(c.ctl.connect(c.beneficio).registrarEtapa(id, E.Secado, 0, h("x")))
        .to.be.revertedWith("Transicion no permitida");
    });
    it("no puede calificar un lote sin trillar", async () => {
      const id = await crear(c.ctl, c.productor);
      await expect(c.ctl.connect(c.qGrader).firmarCalificacion(id, 8500, h("x")))
        .to.be.revertedWith("Transicion no permitida");
    });
    it("humedad fuera de rango", async () => {
      const id = await crear(c.ctl, c.productor);
      await c.ctl.connect(c.beneficio).registrarEtapa(id, E.EnBeneficio, 1500, h("x"));
      await c.ctl.connect(c.beneficio).registrarEtapa(id, E.Secado, 0, h("x"));
      await expect(c.ctl.connect(c.beneficio).registrarEtapa(id, E.Almacenado, 150, h("x")))
        .to.be.revertedWith("Humedad fuera de rango (10-12%)");
    });
    it("la recepción no coincide en peso", async () => {
      const id = await crear(c.ctl, c.productor);
      await hastaCalificado(c, id);
      await c.ctl.connect(c.beneficio).cambiarCustodia(id, c.transportista.address, 1200, 20);
      await expect(c.ctl.connect(c.transportista).aceptarCustodia(id, 1150, 20))
        .to.be.revertedWith("Peso o sacos no coinciden");
    });
    it("un lote en disputa no avanza", async () => {
      const id = await crear(c.ctl, c.productor);
      await c.ctl.connect(c.productor).abrirDisputa(id, h("peso dudoso"));
      await expect(c.ctl.connect(c.beneficio).registrarEtapa(id, E.EnBeneficio, 1500, h("x")))
        .to.be.revertedWith("Transicion no permitida");
    });
  });

  describe("5. rechaza operaciones sin permisos", () => {
    it("una cuenta sin rol no puede crear lotes", async () => {
      await expect(c.ctl.connect(c.intruso).crearLote("F", "R", "V", 1, 0, 0, 1, 1))
        .to.be.revertedWith("Rol no autorizado");
    });
    it("el productor no puede firmar la calificación", async () => {
      const id = await crear(c.ctl, c.productor);
      await expect(c.ctl.connect(c.productor).firmarCalificacion(id, 9000, h("x")))
        .to.be.revertedWith("Rol no autorizado");
    });
    it("solo el custodio actual puede entregar el lote", async () => {
      const id = await crear(c.ctl, c.productor);
      await hastaCalificado(c, id);
      await expect(c.ctl.connect(c.transportista).cambiarCustodia(id, c.transportista.address, 1200, 20))
        .to.be.revertedWith("No es el custodio actual");
    });
    it("solo comité o auditor resuelven disputas", async () => {
      const id = await crear(c.ctl, c.productor);
      await c.ctl.connect(c.productor).abrirDisputa(id, h("motivo"));
      await expect(c.ctl.connect(c.productor).resolverDisputa(id, true, h("x")))
        .to.be.revertedWith("Rol no autorizado");
    });
  });

  it("disputa: congela y vuelve al estado previo o anula", async () => {
    const id = await crear(c.ctl, c.productor);
    await c.ctl.connect(c.beneficio).registrarEtapa(id, E.EnBeneficio, 1500, h("x"));
    await c.ctl.connect(c.beneficio).abrirDisputa(id, h("motivo"));
    expect((await c.ctl.consultarLote(id)).estado).to.equal(E.Disputa);
    await c.ctl.connect(c.comite).resolverDisputa(id, true, h("informe"));
    expect((await c.ctl.consultarLote(id)).estado).to.equal(E.EnBeneficio);

    await c.ctl.connect(c.auditor).abrirDisputa(id, h("motivo 2"));
    await c.ctl.connect(c.auditor).resolverDisputa(id, false, h("informe 2"));
    expect((await c.ctl.consultarLote(id)).estado).to.equal(E.Anulado);
  });

  it("plazo: marca incumplimiento si el beneficio recibe tarde", async () => {
    const id = await crear(c.ctl, c.productor);
    await time.increase(24 * 3600);
    await expect(c.ctl.connect(c.beneficio).registrarEtapa(id, E.EnBeneficio, 1500, h("x")))
      .to.emit(c.ctl, "PlazoIncumplido");
    expect(await c.ctl.incumplimiento(id, E.EnBeneficio)).to.equal(true);
  });

  it("mezcla: crea lote nuevo y pasa los de origen a Mezclado", async () => {
    const a = await crear(c.ctl, c.productor);
    const b = await crear(c.ctl, c.productor);
    for (const id of [a, b]) {
      await c.ctl.connect(c.beneficio).registrarEtapa(id, E.EnBeneficio, 1500, h("x"));
      await c.ctl.connect(c.beneficio).registrarEtapa(id, E.Secado, 0, h("x"));
      await c.ctl.connect(c.beneficio).registrarEtapa(id, E.Almacenado, 110, h("x"));
    }
    await c.ctl.connect(c.beneficio).crearLoteMezcla([a, b]);
    const n = await c.ctl.consultarLote(3);
    expect(n.estado).to.equal(E.Almacenado);
    expect(n.lotesOrigen).to.deep.equal([a, b]);
    expect((await c.ctl.consultarLote(a)).estado).to.equal(E.Mezclado);
  });
});
