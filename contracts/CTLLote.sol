// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title CTL-Lote: gemelo digital del lote de café (CaféTrace Lote)
/// @notice Prototipo de la Actividad 5. Implementa solo CTL-Lote.
///         Ajuste: los roles se fijan en el constructor (reemplaza a CTL-Roles)
///         y no hay llamadas a CTL-Pago.
contract CTLLote {
    // ---------------------------------------------------------------- tipos

    enum Rol { Ninguno, Productor, Beneficio, QGrader, Transportista, Tostador, Cafeteria, Auditor, Comite, Gateway }

    enum Estado {
        Registrado, EnBeneficio, Secado, Almacenado, Trillado, Calificado,
        EnTransporte, RecibidoPorTostador, Tostado, Empaquetado, Entregado,
        Mezclado, Disputa, Anulado
    }

    enum TipoProceso { Lavado, Natural, Honey, Otro }

    enum NivelVerificacion { Declarado, VerificadoTercero, Sensorizado, Auditado }

    struct Lote {
        Estado estado;
        Estado estadoAnterior;     // al que vuelve si la disputa se resuelve a favor
        address productor;
        address custodioActual;
        string finca;
        string region;
        string variedad;
        uint16 altitud;            // m s. n. m.
        TipoProceso tipoProceso;
        uint256 fechaCosecha;
        uint32 pesoEstimadoKg;
        uint32 pesoRecepcionKg;
        uint16 humedadFinal;       // décimas de % (115 = 11,5 %)
        uint32 pesoVerdeKg;
        uint16 cantidadSacos;
        uint16 puntajeSCA;         // centésimas (8550 = 85,50)
        address qGrader;
        bytes32 hashFicha;
        bytes32 motivoDisputa;
        uint256[] lotesOrigen;     // solo si es una mezcla
    }

    struct Evidencia {
        bytes32 hash;
        string uri;
        NivelVerificacion nivel;
        address firmante;
        uint256 fecha;
    }

    struct Traspaso {
        address entrega;
        address recibe;
        uint32 pesoKg;
        uint16 sacos;
        uint256 fecha;
    }

    // --------------------------------------------------------------- estado

    mapping(address => Rol) public rolDe;
    mapping(Estado => uint256) public plazoMaximo; // segundos desde la etapa anterior; 0 = sin plazo

    uint256 public cantidadLotes;
    mapping(uint256 => Lote) private lotes;
    mapping(uint256 => mapping(Estado => uint256)) public marcaTiempo;
    mapping(uint256 => mapping(Estado => bool)) public incumplimiento;
    mapping(uint256 => mapping(address => bool)) public participa;
    mapping(uint256 => Evidencia[]) private evidencias;
    mapping(uint256 => Traspaso[]) private historialCustodia;
    mapping(uint256 => Traspaso) public traspasoPendiente;

    // -------------------------------------------------------------- eventos

    event LoteCreado(uint256 indexed loteId, address indexed productor);
    event EtapaRegistrada(uint256 indexed loteId, Estado desde, Estado hacia, address firmante);
    event PlazoIncumplido(uint256 indexed loteId, Estado etapa, uint256 demora);
    event EvidenciaRegistrada(uint256 indexed loteId, bytes32 hash, NivelVerificacion nivel, address firmante);
    event PesoVerificado(uint256 indexed loteId, uint32 pesoVerdeKg);
    event LoteCalificado(uint256 indexed loteId, uint16 puntajeSCA, address qGrader);
    event CustodiaPropuesta(uint256 indexed loteId, address entrega, address recibe);
    event CustodiaTransferida(uint256 indexed loteId, address entrega, address recibe, uint32 pesoKg);
    event LoteMezclado(uint256 indexed nuevoLoteId, uint256[] lotesOrigen);
    event DisputaAbierta(uint256 indexed loteId, bytes32 motivo, address quien);
    event DisputaResuelta(uint256 indexed loteId, bool aFavor);

    // ------------------------------------------------------------ modifiers

    modifier soloRol(Rol r) {
        require(rolDe[msg.sender] == r, "Rol no autorizado");
        _;
    }

    modifier existe(uint256 loteId) {
        require(loteId > 0 && loteId <= cantidadLotes, "Lote inexistente");
        _;
    }

    // ---------------------------------------------------------- constructor

    /// @dev Roles hardcodeados al desplegar: cuentas[i] recibe roles[i].
    constructor(address[] memory cuentas, Rol[] memory roles) {
        require(cuentas.length == roles.length, "Largos distintos");
        for (uint256 i = 0; i < cuentas.length; i++) rolDe[cuentas[i]] = roles[i];

        // Reglas de tiempo (ejemplos del TP; en el modelo las configura el comité)
        plazoMaximo[Estado.EnBeneficio] = 12 hours; // cosecha -> recepción en beneficio
        plazoMaximo[Estado.Almacenado] = 30 days;   // duración del secado
        plazoMaximo[Estado.Entregado] = 21 days;    // ventana de frescura (desde el empaque)
    }

    // ------------------------------------------------------------- funciones

    function crearLote(
        string calldata finca,
        string calldata region,
        string calldata variedad,
        uint16 altitud,
        TipoProceso tipoProceso,
        uint256 fechaCosecha,
        uint32 pesoEstimadoKg,
        uint16 cantidadSacos
    ) external soloRol(Rol.Productor) returns (uint256 loteId) {
        require(pesoEstimadoKg > 0, "Peso estimado invalido");
        require(fechaCosecha <= block.timestamp, "Cosecha en el futuro");

        loteId = ++cantidadLotes;
        Lote storage l = lotes[loteId];
        l.productor = msg.sender;
        l.custodioActual = msg.sender;
        l.finca = finca;
        l.region = region;
        l.variedad = variedad;
        l.altitud = altitud;
        l.tipoProceso = tipoProceso;
        l.fechaCosecha = fechaCosecha;
        l.pesoEstimadoKg = pesoEstimadoKg;
        l.cantidadSacos = cantidadSacos;
        // estado = Registrado (valor por defecto)

        marcaTiempo[loteId][Estado.Registrado] = block.timestamp;
        participa[loteId][msg.sender] = true;
        emit LoteCreado(loteId, msg.sender);
    }

    /// @notice Transiciones "simples" del DTE.
    /// @param valor depende de la etapa destino:
    ///        EnBeneficio -> peso de recepción (kg); Almacenado -> humedad final (décimas de %);
    ///        resto -> se ignora.
    function registrarEtapa(uint256 loteId, Estado hacia, uint32 valor, bytes32 hashEvidencia)
        external
        existe(loteId)
    {
        Lote storage l = lotes[loteId];
        Estado desde = l.estado;
        Rol rol = rolDe[msg.sender];

        if (desde == Estado.Registrado && hacia == Estado.EnBeneficio) {
            require(rol == Rol.Beneficio, "Rol no autorizado");
            require(valor > 0, "Peso de recepcion invalido");
            l.pesoRecepcionKg = valor;
            l.custodioActual = msg.sender;
        } else if (desde == Estado.EnBeneficio && hacia == Estado.Secado) {
            _soloCustodio(l, Rol.Beneficio);
        } else if (desde == Estado.Secado && hacia == Estado.Almacenado) {
            _soloCustodio(l, Rol.Beneficio);
            require(valor >= 100 && valor <= 120, "Humedad fuera de rango (10-12%)");
            l.humedadFinal = uint16(valor);
        } else if (desde == Estado.RecibidoPorTostador && hacia == Estado.Tostado) {
            _soloCustodio(l, Rol.Tostador);
        } else if (desde == Estado.Tostado && hacia == Estado.Empaquetado) {
            _soloCustodio(l, Rol.Tostador);
        } else {
            revert("Transicion no permitida");
        }

        _avanzar(loteId, hacia, hashEvidencia, NivelVerificacion.Declarado);
    }

    /// @notice Almacenado -> Trillado. Fija el peso verde verificado.
    function registrarPesoVerde(uint256 loteId, uint32 pesoVerdeKg, uint16 cantidadSacos, bytes32 hashEvidencia)
        external
        existe(loteId)
    {
        Lote storage l = lotes[loteId];
        require(l.estado == Estado.Almacenado, "Transicion no permitida");
        _soloCustodio(l, Rol.Beneficio);
        require(pesoVerdeKg > 0, "Peso verde invalido");
        require(l.pesoRecepcionKg == 0 || pesoVerdeKg <= l.pesoRecepcionKg, "Peso verde mayor al recibido");

        l.pesoVerdeKg = pesoVerdeKg;
        l.cantidadSacos = cantidadSacos;
        _avanzar(loteId, Estado.Trillado, hashEvidencia, NivelVerificacion.VerificadoTercero);
        emit PesoVerificado(loteId, pesoVerdeKg);
    }

    /// @notice Trillado -> Calificado. Solo un Q Grader sin relación con el productor.
    function firmarCalificacion(uint256 loteId, uint16 puntajeSCA, bytes32 hashFicha)
        external
        existe(loteId)
        soloRol(Rol.QGrader)
    {
        Lote storage l = lotes[loteId];
        require(l.estado == Estado.Trillado, "Transicion no permitida");
        require(msg.sender != l.productor, "Q Grader relacionado con el productor");
        require(puntajeSCA <= 10000, "Puntaje invalido");

        l.puntajeSCA = puntajeSCA;
        l.qGrader = msg.sender;
        l.hashFicha = hashFicha;
        _avanzar(loteId, Estado.Calificado, hashFicha, NivelVerificacion.VerificadoTercero);
        emit LoteCalificado(loteId, puntajeSCA, msg.sender);
    }

    /// @notice Paso 1 de la doble firma: el custodio actual propone entregar el lote.
    ///         Calificado -> EnTransporte (a Transportista),
    ///         EnTransporte -> RecibidoPorTostador (a Tostador),
    ///         Empaquetado -> Entregado (a Cafetería).
    function cambiarCustodia(uint256 loteId, address receptor, uint32 pesoKg, uint16 sacos)
        external
        existe(loteId)
    {
        Lote storage l = lotes[loteId];
        require(msg.sender == l.custodioActual, "No es el custodio actual");
        (, Rol rolReceptor) = _destinoCustodia(l.estado);
        require(rolDe[receptor] == rolReceptor, "Receptor sin el rol requerido");

        traspasoPendiente[loteId] = Traspaso(msg.sender, receptor, pesoKg, sacos, block.timestamp);
        emit CustodiaPropuesta(loteId, msg.sender, receptor);
    }

    /// @notice Paso 2 de la doble firma: el receptor confirma peso y sacos y el lote avanza.
    function aceptarCustodia(uint256 loteId, uint32 pesoKg, uint16 sacos) external existe(loteId) {
        Lote storage l = lotes[loteId];
        Traspaso memory t = traspasoPendiente[loteId];
        require(t.recibe != address(0) && t.recibe == msg.sender, "No hay traspaso para esta cuenta");
        require(t.entrega == l.custodioActual, "Traspaso obsoleto");
        require(t.pesoKg == pesoKg && t.sacos == sacos, "Peso o sacos no coinciden");
        (Estado hacia,) = _destinoCustodia(l.estado);

        delete traspasoPendiente[loteId];
        t.fecha = block.timestamp;
        historialCustodia[loteId].push(t);
        l.custodioActual = msg.sender;
        _avanzar(loteId, hacia, bytes32(0), NivelVerificacion.VerificadoTercero);
        emit CustodiaTransferida(loteId, t.entrega, msg.sender, pesoKg);
    }

    /// @notice Crea un lote nuevo a partir de otros; los de origen pasan a Mezclado.
    ///         Todos los lotes de origen deben estar en el mismo estado (Almacenado o Trillado).
    function crearLoteMezcla(uint256[] calldata origenes)
        external
        soloRol(Rol.Beneficio)
        returns (uint256 loteId)
    {
        require(origenes.length >= 2, "Se necesitan al menos 2 lotes");
        Estado estadoComun = lotes[origenes[0]].estado;
        require(estadoComun == Estado.Almacenado || estadoComun == Estado.Trillado, "Estado no mezclable");

        loteId = ++cantidadLotes;
        Lote storage n = lotes[loteId];
        for (uint256 i = 0; i < origenes.length; i++) {
            uint256 o = origenes[i];
            require(o > 0 && o < loteId, "Lote inexistente");
            Lote storage l = lotes[o];
            require(l.estado == estadoComun, "Estados distintos");
            require(l.custodioActual == msg.sender, "No es el custodio actual");
            n.pesoEstimadoKg += l.pesoEstimadoKg;
            n.pesoRecepcionKg += l.pesoRecepcionKg;
            n.pesoVerdeKg += l.pesoVerdeKg;
            n.cantidadSacos += l.cantidadSacos;
            l.estadoAnterior = l.estado;
            l.estado = Estado.Mezclado;
            marcaTiempo[o][Estado.Mezclado] = block.timestamp;
            emit EtapaRegistrada(o, estadoComun, Estado.Mezclado, msg.sender);
        }
        n.estado = estadoComun;
        n.productor = msg.sender;
        n.custodioActual = msg.sender;
        n.finca = "Mezcla";
        n.tipoProceso = TipoProceso.Otro;
        n.fechaCosecha = block.timestamp;
        n.lotesOrigen = origenes;
        marcaTiempo[loteId][estadoComun] = block.timestamp;
        participa[loteId][msg.sender] = true;
        emit LoteMezclado(loteId, origenes);
    }

    /// @notice Congela el lote. Puede abrirla cualquier participante del lote, el comité o un auditor.
    function abrirDisputa(uint256 loteId, bytes32 motivo) external existe(loteId) {
        Lote storage l = lotes[loteId];
        Rol rol = rolDe[msg.sender];
        require(participa[loteId][msg.sender] || rol == Rol.Comite || rol == Rol.Auditor, "No participa del lote");
        require(motivo != bytes32(0), "Motivo requerido");
        require(!_esFinal(l.estado) && l.estado != Estado.Disputa, "Lote cerrado o ya en disputa");

        delete traspasoPendiente[loteId];
        l.estadoAnterior = l.estado;
        l.estado = Estado.Disputa;
        l.motivoDisputa = motivo;
        emit DisputaAbierta(loteId, motivo, msg.sender);
    }

    /// @notice Devuelve el lote a su estado previo (aFavor) o lo anula.
    function resolverDisputa(uint256 loteId, bool aFavor, bytes32 hashInforme) external existe(loteId) {
        Rol rol = rolDe[msg.sender];
        require(rol == Rol.Comite || rol == Rol.Auditor, "Rol no autorizado");
        Lote storage l = lotes[loteId];
        require(l.estado == Estado.Disputa, "Lote sin disputa");

        l.estado = aFavor ? l.estadoAnterior : Estado.Anulado;
        l.motivoDisputa = bytes32(0);
        if (hashInforme != bytes32(0)) _guardarEvidencia(loteId, hashInforme, "", NivelVerificacion.Auditado);
        emit DisputaResuelta(loteId, aFavor);
    }

    /// @notice Agrega evidencia. El nivel no lo elige quien firma: lo define su rol.
    function registrarEvidencia(uint256 loteId, bytes32 hash, string calldata uri) external existe(loteId) {
        Rol rol = rolDe[msg.sender];
        require(participa[loteId][msg.sender] || rol == Rol.Gateway || rol == Rol.Auditor, "No participa del lote");
        Estado e = lotes[loteId].estado;
        require(e != Estado.Anulado && e != Estado.Mezclado, "Lote inactivo");

        NivelVerificacion nivel = rol == Rol.Gateway
            ? NivelVerificacion.Sensorizado
            : rol == Rol.Auditor ? NivelVerificacion.Auditado : NivelVerificacion.Declarado;
        _guardarEvidencia(loteId, hash, uri, nivel);
    }

    // ------------------------------------------------------------ consultas

    function consultarLote(uint256 loteId) external view existe(loteId) returns (Lote memory) {
        return lotes[loteId];
    }

    function consultarEvidencias(uint256 loteId) external view returns (Evidencia[] memory) {
        return evidencias[loteId];
    }

    function consultarHistorialCustodia(uint256 loteId) external view returns (Traspaso[] memory) {
        return historialCustodia[loteId];
    }

    // ------------------------------------------------------------ internas

    function _soloCustodio(Lote storage l, Rol r) private view {
        require(rolDe[msg.sender] == r, "Rol no autorizado");
        require(msg.sender == l.custodioActual, "No es el custodio actual");
    }

    function _destinoCustodia(Estado e) private pure returns (Estado hacia, Rol rolReceptor) {
        if (e == Estado.Calificado) return (Estado.EnTransporte, Rol.Transportista);
        if (e == Estado.EnTransporte) return (Estado.RecibidoPorTostador, Rol.Tostador);
        if (e == Estado.Empaquetado) return (Estado.Entregado, Rol.Cafeteria);
        revert("Transicion no permitida");
    }

    function _esFinal(Estado e) private pure returns (bool) {
        return e == Estado.Entregado || e == Estado.Mezclado || e == Estado.Anulado;
    }

    /// @dev Avanza el estado, sella la fecha, controla el plazo y guarda la evidencia.
    function _avanzar(uint256 loteId, Estado hacia, bytes32 hashEvidencia, NivelVerificacion nivel) private {
        Lote storage l = lotes[loteId];
        Estado desde = l.estado;

        uint256 inicio = hacia == Estado.EnBeneficio ? l.fechaCosecha : marcaTiempo[loteId][desde];
        uint256 plazo = plazoMaximo[hacia];
        if (plazo > 0 && block.timestamp > inicio + plazo) {
            incumplimiento[loteId][hacia] = true;
            emit PlazoIncumplido(loteId, hacia, block.timestamp - inicio - plazo);
        }

        l.estado = hacia;
        marcaTiempo[loteId][hacia] = block.timestamp;
        participa[loteId][msg.sender] = true;
        if (hashEvidencia != bytes32(0)) _guardarEvidencia(loteId, hashEvidencia, "", nivel);
        emit EtapaRegistrada(loteId, desde, hacia, msg.sender);
    }

    function _guardarEvidencia(uint256 loteId, bytes32 hash, string memory uri, NivelVerificacion nivel) private {
        evidencias[loteId].push(Evidencia(hash, uri, nivel, msg.sender, block.timestamp));
        emit EvidenciaRegistrada(loteId, hash, nivel, msg.sender);
    }
}
