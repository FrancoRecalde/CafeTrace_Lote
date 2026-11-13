// Roles hardcodeados: cada cuenta de prueba de Hardhat recibe un rol fijo.
// Debe coincidir con el enum Rol del contrato.
const Rol = { Ninguno: 0, Productor: 1, Beneficio: 2, QGrader: 3, Transportista: 4, Tostador: 5, Cafeteria: 6, Auditor: 7, Comite: 8, Gateway: 9 };

const Estado = [
  "Registrado", "EnBeneficio", "Secado", "Almacenado", "Trillado", "Calificado",
  "EnTransporte", "RecibidoPorTostador", "Tostado", "Empaquetado", "Entregado",
  "Mezclado", "Disputa", "Anulado",
];
const E = Object.fromEntries(Estado.map((n, i) => [n, i]));

async function desplegar(ethers) {
  const [comite, productor, beneficio, qGrader, transportista, tostador, cafeteria, auditor, gateway, intruso] =
    await ethers.getSigners();
  const cuentas = { comite, productor, beneficio, qGrader, transportista, tostador, cafeteria, auditor, gateway, intruso };
  const asignacion = [
    [comite, Rol.Comite], [productor, Rol.Productor], [beneficio, Rol.Beneficio], [qGrader, Rol.QGrader],
    [transportista, Rol.Transportista], [tostador, Rol.Tostador], [cafeteria, Rol.Cafeteria],
    [auditor, Rol.Auditor], [gateway, Rol.Gateway],
    // intruso: sin rol
  ];
  const ctl = await ethers.deployContract("CTLLote", [asignacion.map(([s]) => s.address), asignacion.map(([, r]) => r)]);
  await ctl.waitForDeployment();
  return { ctl, ...cuentas };
}

module.exports = { Rol, Estado, E, desplegar };
