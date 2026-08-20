/* ===========================================================================
   NOME       : arvore-de-bloqueio-hierarquica.sql
   OBJETIVO   : Montar a cadeia completa de bloqueio em forma de arvore, da
                sessao RAIZ ate a ultima vitima, para que se saiba exatamente
                qual sessao esta na origem do problema.

   COMPATIBILIDADE : SQL Server 2012+ (11.x). Azure SQL Database: sim.
   IMPACTO         : Nenhum. Somente leitura sobre DMVs.
   PERMISSOES      : VIEW SERVER STATE.
   TEMPO ESTIMADO  : < 2 segundos.

   POR QUE IMPORTA : Em uma cadeia A -> B -> C -> D, matar C nao resolve nada:
                A continua bloqueando B. Pior, matar uma vitima intermediaria
                pode disparar um rollback longo e agravar o incidente. A unica
                sessao que interessa e a RAIZ (nivel 0).

   ATENCAO    : Auto-bloqueio por paralelismo (blocking_session_id igual ao
                proprio session_id) e excluido de proposito -- nao e bloqueio
                entre sessoes e criaria recursao infinita.

   AUTOR      : Fabio Cerqueira
   =========================================================================== */

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

WITH Envolvidos AS
(
    /* sessoes que estao sendo bloqueadas */
    SELECT
        session_id          = r.session_id,
        blocking_session_id = r.blocking_session_id
    FROM sys.dm_exec_requests AS r
    WHERE r.blocking_session_id <> 0
      AND r.blocking_session_id <> r.session_id

    UNION

    /* raizes da cadeia: bloqueadores que nao estao, eles proprios, bloqueados.
       Cobre tanto o bloqueador 'sleeping' (sem linha em dm_exec_requests)
       quanto o bloqueador em execucao com blocking_session_id = 0. */
    SELECT DISTINCT
        session_id          = r.blocking_session_id,
        blocking_session_id = 0
    FROM sys.dm_exec_requests AS r
    WHERE r.blocking_session_id <> 0
      AND r.blocking_session_id <> r.session_id
      AND NOT EXISTS (
              SELECT 1
              FROM sys.dm_exec_requests AS r2
              WHERE r2.session_id = r.blocking_session_id
                AND r2.blocking_session_id <> 0
                AND r2.blocking_session_id <> r2.session_id)
),
Arvore AS
(
    /* nivel 0 = raiz da cadeia */
    SELECT
        e.session_id,
        e.blocking_session_id,
        nivel   = 0,
        caminho = CAST(CAST(e.session_id AS VARCHAR(10)) AS VARCHAR(900))
    FROM Envolvidos AS e
    WHERE e.blocking_session_id = 0

    UNION ALL

    SELECT
        e.session_id,
        e.blocking_session_id,
        nivel   = a.nivel + 1,
        caminho = CAST(a.caminho + ' > ' + CAST(e.session_id AS VARCHAR(10)) AS VARCHAR(900))
    FROM Envolvidos AS e
    INNER JOIN Arvore AS a
            ON a.session_id = e.blocking_session_id
)
SELECT
    papel = CASE
                WHEN a.nivel = 0 THEN '*** RAIZ - E ESTA QUE IMPORTA ***'
                ELSE 'vitima nivel ' + CAST(a.nivel AS VARCHAR(3))
            END,
    hierarquia   = REPLICATE('    ', a.nivel) + '+-- ' + CAST(a.session_id AS VARCHAR(10)),
    a.session_id,
    a.blocking_session_id,
    a.caminho,
    status_sessao   = s.status,
    transacoes_abertas = s.open_transaction_count,
    login           = s.login_name,
    host            = s.host_name,
    programa        = s.program_name,
    ocioso_desde    = CASE WHEN s.status = 'sleeping' THEN s.last_request_end_time END,
    esperando_seg   = r.wait_time / 1000,
    r.wait_type,
    r.wait_resource,
    banco           = DB_NAME(COALESCE(r.database_id, s.database_id)),
    comando         = COALESCE(txt_req.text, txt_conn.text)
FROM Arvore AS a
LEFT JOIN sys.dm_exec_sessions AS s
       ON s.session_id = a.session_id
LEFT JOIN sys.dm_exec_requests AS r
       ON r.session_id = a.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS txt_req
OUTER APPLY (
        SELECT TOP (1) c.most_recent_sql_handle
        FROM sys.dm_exec_connections AS c
        WHERE c.session_id = a.session_id
        ORDER BY c.connect_time DESC
    ) AS conn
OUTER APPLY sys.dm_exec_sql_text(conn.most_recent_sql_handle) AS txt_conn
ORDER BY a.caminho
OPTION (MAXRECURSION 100);

/* ===========================================================================
   COMO LER O RESULTADO

   A coluna 'hierarquia' desenha a arvore. A linha marcada como RAIZ e a origem
   de todo o bloqueio.

   Exemplo de saida:

       papel                              hierarquia          status
       ---------------------------------  ------------------  --------
       *** RAIZ - E ESTA QUE IMPORTA ***  +-- 55              sleeping
       vitima nivel 1                         +-- 71          suspended
       vitima nivel 2                             +-- 83      suspended
       vitima nivel 1                         +-- 92          suspended

   Leitura: a sessao 55 esta DORMINDO com transacao aberta e bloqueia 71 e 92;
   a 71 por sua vez bloqueia a 83. Matar 71 ou 83 nao resolve nada. O problema
   e a 55 -- e a correcao definitiva e no codigo da aplicacao que a abriu.

   SE MAXRECURSION FOR ATINGIDO (erro 530): a cadeia tem mais de 100 niveis,
   o que indica um incidente grave de bloqueio em massa. Aumente o limite ou
   trate como emergencia.
   =========================================================================== */
