/* ===========================================================================
   NOME       : sessoes-e-requests-em-execucao.sql
   OBJETIVO   : Visao completa do que esta acontecendo na instancia neste
                instante: sessoes ativas, sessoes ociosas com transacao aberta,
                e conexoes agrupadas por aplicacao.

   COMPATIBILIDADE : SQL Server 2012+ (11.x). Azure SQL Database: sim.
   IMPACTO         : Nenhum. Somente leitura sobre DMVs.
   PERMISSOES      : VIEW SERVER STATE.
   TEMPO ESTIMADO  : < 2 segundos.

   POR QUE ESTE SCRIPT E NAO sp_who2 : sp_who2 nao mostra o texto da query,
                nao mostra a espera atual e nao permite ordenar nem filtrar.
                Este script responde as mesmas perguntas com contexto.

   AUTOR      : Fabio Cerqueira
   =========================================================================== */

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

/* ---------------------------------------------------------------------------
   BLOCO 1 - Requests em execucao, do mais demorado para o mais recente
   --------------------------------------------------------------------------- */
SELECT
    r.session_id,
    r.blocking_session_id,
    r.status,
    r.command,
    duracao_seg     = r.total_elapsed_time / 1000,
    cpu_seg         = r.cpu_time / 1000,
    r.logical_reads,
    r.reads,
    r.writes,
    r.wait_type,
    espera_ms       = r.wait_time,
    r.wait_resource,
    r.open_transaction_count,
    banco           = DB_NAME(r.database_id),
    s.login_name,
    s.host_name,
    s.program_name,
    s.client_interface_name,
    grau_paralelismo = r.dop,
    memoria_concedida_kb = r.granted_query_memory * 8,
    percentual_concluido = r.percent_complete,
    comando_atual   = SUBSTRING(
                          t.text,
                          (r.statement_start_offset / 2) + 1,
                          ((CASE r.statement_end_offset
                                WHEN -1 THEN DATALENGTH(t.text)
                                ELSE r.statement_end_offset
                            END - r.statement_start_offset) / 2) + 1),
    lote_completo   = t.text,
    plano           = p.query_plan
FROM sys.dm_exec_requests AS r
INNER JOIN sys.dm_exec_sessions AS s
        ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle)       AS t
OUTER APPLY sys.dm_exec_query_plan(r.plan_handle)    AS p
WHERE s.is_user_process = 1
  AND r.session_id <> @@SPID
ORDER BY r.total_elapsed_time DESC;


/* ---------------------------------------------------------------------------
   BLOCO 2 - Sessoes OCIOSAS com transacao aberta
   Este bloco costuma ser o mais revelador: sao as sessoes que nao estao
   fazendo nada e mesmo assim seguram locks.
   --------------------------------------------------------------------------- */
SELECT
    s.session_id,
    s.status,
    s.open_transaction_count,
    ocioso_ha_min   = DATEDIFF(MINUTE, s.last_request_end_time, SYSDATETIME()),
    s.last_request_start_time,
    s.last_request_end_time,
    s.login_name,
    s.host_name,
    s.program_name,
    banco           = DB_NAME(s.database_id),
    bloqueando      = (SELECT COUNT(*)
                       FROM sys.dm_exec_requests AS b
                       WHERE b.blocking_session_id = s.session_id),
    ultimo_comando  = t.text
FROM sys.dm_exec_sessions AS s
OUTER APPLY (
        SELECT TOP (1) c.most_recent_sql_handle
        FROM sys.dm_exec_connections AS c
        WHERE c.session_id = s.session_id
        ORDER BY c.connect_time DESC
    ) AS conn
OUTER APPLY sys.dm_exec_sql_text(conn.most_recent_sql_handle) AS t
WHERE s.is_user_process = 1
  AND s.status = 'sleeping'
  AND s.open_transaction_count > 0
ORDER BY s.last_request_end_time ASC;


/* ---------------------------------------------------------------------------
   BLOCO 3 - Conexoes agrupadas por aplicacao, host e login
   Util para descobrir qual aplicacao esta abrindo conexoes demais.
   --------------------------------------------------------------------------- */
SELECT
    programa           = ISNULL(s.program_name, '(nao informado)'),
    host               = ISNULL(s.host_name, '(nao informado)'),
    s.login_name,
    total_sessoes      = COUNT(*),
    sessoes_ativas     = SUM(CASE WHEN s.status = 'running'
                                    OR s.status = 'runnable' THEN 1 ELSE 0 END),
    sessoes_ociosas    = SUM(CASE WHEN s.status = 'sleeping'  THEN 1 ELSE 0 END),
    com_transacao_aberta = SUM(CASE WHEN s.open_transaction_count > 0 THEN 1 ELSE 0 END),
    conexao_mais_antiga  = MIN(s.login_time)
FROM sys.dm_exec_sessions AS s
WHERE s.is_user_process = 1
GROUP BY s.program_name, s.host_name, s.login_name
ORDER BY total_sessoes DESC;

/* ===========================================================================
   COMO LER O RESULTADO

   BLOCO 2 com linhas
       Sessoes ociosas com transacao aberta. Se a coluna 'bloqueando' for
       maior que zero, achou a causa do incidente.

   BLOCO 3 com um programa concentrando centenas de sessoes
       Possivel vazamento de conexao na aplicacao (SqlConnection sem Dispose)
       ou pool mal dimensionado. Veja
       ../../acesso-a-dados/ado-net/connection-pool-esgotado.md

   programa = '(nao informado)' ou '.Net SqlClient Data Provider' em tudo
       Configure Application Name na connection string de cada aplicacao.
       Sem isso, nenhum diagnostico consegue apontar QUAL sistema causou o
       problema. E o ajuste de observabilidade mais barato que existe:

           Server=<SERVIDOR>;Database=<BANCO>;...;Application Name=<SISTEMA>
   =========================================================================== */
