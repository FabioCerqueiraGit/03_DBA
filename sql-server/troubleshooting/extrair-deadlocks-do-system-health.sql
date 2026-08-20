/* ===========================================================================
   NOME       : extrair-deadlocks-do-system-health.sql
   OBJETIVO   : Extrair os deadlocks ja capturados pela sessao de Extended
                Events 'system_health', que fica ATIVA POR PADRAO no SQL
                Server -- ou seja, os deadlocks recentes ja estao gravados,
                mesmo que ninguem tenha configurado nada.

   COMPATIBILIDADE : SQL Server 2012+ (11.x).
                     Azure SQL Database: a sessao system_health tambem existe,
                     mas o alvo em arquivo pode nao estar acessivel; use a
                     consulta do BLOCO 2 (ring buffer).
   IMPACTO         : Baixo. Leitura e parsing de XML em memoria. Em servidor
                     muito ocupado, prefira executar fora do pico.
   PERMISSOES      : VIEW SERVER STATE.
   TEMPO ESTIMADO  : 2 a 30 segundos, conforme o volume do buffer.

   POR QUE IMPORTA : a pergunta "tivemos deadlock ontem as 15h?" ja tem
                resposta gravada na instancia. Nao e preciso reproduzir o
                problema nem ligar trace flag para investigar.

   AUTOR      : Fabio Cerqueira
   =========================================================================== */

SET NOCOUNT ON;

/* ---------------------------------------------------------------------------
   BLOCO 1 - Deadlocks a partir do alvo em ARQUIVO da system_health
   Cobre um periodo maior (varios dias, conforme rotacao dos arquivos .xel).
   Esta e a consulta preferencial.
   --------------------------------------------------------------------------- */
DECLARE @caminho NVARCHAR(400);

/* Descobre sozinho onde estao os arquivos .xel da system_health,
   sem depender do caminho padrao de instalacao. */
SELECT TOP (1)
    @caminho = LEFT(CAST(f.value AS NVARCHAR(400)),
                    LEN(CAST(f.value AS NVARCHAR(400)))
                    - CHARINDEX(N'\', REVERSE(CAST(f.value AS NVARCHAR(400)))))
             + N'\system_health*.xel'
FROM sys.server_event_session_fields AS f
INNER JOIN sys.server_event_sessions AS s
        ON s.event_session_id = f.event_session_id
WHERE s.name = N'system_health'
  AND f.name = N'filename';

IF @caminho IS NOT NULL
BEGIN
    ;WITH Eventos AS
    (
        SELECT dados = CAST(x.event_data AS XML)
        FROM sys.fn_xe_file_target_read_file(@caminho, NULL, NULL, NULL) AS x
        WHERE x.object_name = N'xml_deadlock_report'
    )
    SELECT
        origem            = 'arquivo system_health',
        ocorrido_em_utc   = dados.value('(event/@timestamp)[1]', 'datetime2(3)'),
        /* o relatorio completo: clique no XML para ver o grafo do deadlock */
        relatorio_xml     = dados.query('(event/data/value/deadlock)[1]'),
        vitima_processo   = dados.value('(event/data/value/deadlock/victim-list/victimProcess/@id)[1]', 'NVARCHAR(50)'),
        procedimentos     = dados.value('(event/data/value/deadlock/process-list/process/executionStack/frame/@procname)[1]', 'NVARCHAR(400)')
    FROM Eventos
    ORDER BY ocorrido_em_utc DESC;
END
ELSE
BEGIN
    PRINT 'Nao foi possivel localizar o alvo em arquivo da system_health. Use o BLOCO 2.';
END
GO


/* ---------------------------------------------------------------------------
   BLOCO 2 - Deadlocks a partir do RING BUFFER da system_health
   Alternativa quando o alvo em arquivo nao esta acessivel (por exemplo em
   Azure SQL Database). Cobre um periodo menor: o buffer e circular e pequeno.
   --------------------------------------------------------------------------- */
;WITH RingBuffer AS
(
    SELECT dados = CAST(t.target_data AS XML)
    FROM sys.dm_xe_session_targets AS t
    INNER JOIN sys.dm_xe_sessions AS s
            ON s.address = t.event_session_address
    WHERE s.name       = N'system_health'
      AND t.target_name = N'ring_buffer'
),
Deadlocks AS
(
    SELECT evento = e.query('.')
    FROM RingBuffer
    CROSS APPLY dados.nodes('//RingBufferTarget/event[@name="xml_deadlock_report"]') AS x(e)
)
SELECT
    origem          = 'ring buffer system_health',
    ocorrido_em_utc = evento.value('(event/@timestamp)[1]', 'datetime2(3)'),
    relatorio_xml   = evento.query('(event/data/value/deadlock)[1]')
FROM Deadlocks
ORDER BY ocorrido_em_utc DESC;

/* ===========================================================================
   COMO LER O RESULTADO

   Clique na celula 'relatorio_xml' para abrir o grafo do deadlock. No XML,
   procure por:

     <victim-list>      qual sessao o SQL Server escolheu como vitima
                        (ele escolhe a de rollback mais barato, nao a culpada)
     <process-list>     os processos envolvidos: cada <process> traz
                        loginname, hostname, clientapp, isolationlevel,
                        lastbatchstarted e o inputbuf com o comando
     <executionStack>   a pilha de execucao, com procname e line -- e aqui que
                        se descobre QUAL PROCEDURE e QUAL LINHA causaram
     <resource-list>    os recursos disputados: objectname mostra a TABELA e o
                        INDICE em disputa; mode mostra o tipo de lock

   O PADRAO MAIS COMUM: duas transacoes acessam as mesmas duas tabelas em
   ORDEM INVERSA. A correcao e padronizar a ordem de acesso, nao aumentar o
   timeout nem adicionar retry cegamente.

   Detalhes de interpretacao e estrategias de correcao: investigar-deadlocks.md
   =========================================================================== */
