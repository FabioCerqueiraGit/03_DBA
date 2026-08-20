/* ===========================================================================
   NOME       : encontrar-transacoes-abertas-longa-duracao.sql
   OBJETIVO   : Listar transacoes abertas, ordenadas da mais antiga para a mais
                nova, com o volume de log que cada uma esta segurando.

   COMPATIBILIDADE : SQL Server 2012+ (11.x). Azure SQL Database: sim.
   IMPACTO         : Nenhum. Somente leitura sobre DMVs.
   PERMISSOES      : VIEW SERVER STATE.
   TEMPO ESTIMADO  : < 2 segundos.

   POR QUE IMPORTA : uma transacao antiga causa TRES problemas ao mesmo tempo,
                e e comum tratar apenas o primeiro:
                  1. bloqueia outras sessoes;
                  2. impede o truncamento do transaction log -- o .ldf cresce
                     ate acabar o disco, mesmo com backup de log em dia;
                  3. segura o version store no tempdb quando ha isolamento de
                     versao de linha ativo -- o tempdb cresce.

   AUTOR      : Fabio Cerqueira
   =========================================================================== */

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

SELECT
    idade_minutos       = DATEDIFF(MINUTE, tat.transaction_begin_time, SYSDATETIME()),
    inicio_transacao    = tat.transaction_begin_time,
    s.session_id,
    status_sessao       = s.status,
    esta_ociosa         = CASE WHEN s.status = 'sleeping'
                               THEN 'SIM - transacao aberta sem trabalho em curso'
                               ELSE 'nao' END,
    login               = s.login_name,
    host                = s.host_name,
    programa            = s.program_name,
    banco               = DB_NAME(dbt.database_id),

    estado_transacao    = CASE tat.transaction_state
                              WHEN 0 THEN 'ainda nao inicializada'
                              WHEN 1 THEN 'inicializada, ainda nao iniciada'
                              WHEN 2 THEN 'ativa'
                              WHEN 3 THEN 'encerrada (somente leitura)'
                              WHEN 4 THEN 'commit distribuido em andamento'
                              WHEN 5 THEN 'preparada, aguardando resolucao'
                              WHEN 6 THEN 'commit efetuado'
                              WHEN 7 THEN 'rollback em andamento'
                              WHEN 8 THEN 'rollback concluido'
                              ELSE CAST(tat.transaction_state AS VARCHAR(10))
                          END,
    tipo_transacao      = CASE tat.transaction_type
                              WHEN 1 THEN 'leitura/escrita'
                              WHEN 2 THEN 'somente leitura'
                              WHEN 3 THEN 'sistema'
                              WHEN 4 THEN 'distribuida'
                              ELSE CAST(tat.transaction_type AS VARCHAR(10))
                          END,

    /* quanto de transaction log esta preso por causa desta transacao */
    log_usado_mb        = dbt.database_transaction_log_bytes_used     / 1024.0 / 1024.0,
    log_reservado_mb    = dbt.database_transaction_log_bytes_reserved / 1024.0 / 1024.0,
    registros_de_log    = dbt.database_transaction_log_record_count,

    bloqueando_alguem   = CASE WHEN EXISTS (SELECT 1
                                            FROM sys.dm_exec_requests AS b
                                            WHERE b.blocking_session_id = s.session_id)
                               THEN 'SIM' ELSE 'nao' END,

    ultimo_comando      = COALESCE(txt_req.text, txt_conn.text)

FROM sys.dm_tran_active_transactions AS tat
INNER JOIN sys.dm_tran_session_transactions AS tst
        ON tst.transaction_id = tat.transaction_id
INNER JOIN sys.dm_exec_sessions AS s
        ON s.session_id = tst.session_id
LEFT JOIN sys.dm_tran_database_transactions AS dbt
       ON dbt.transaction_id = tat.transaction_id
LEFT JOIN sys.dm_exec_requests AS r
       ON r.session_id = s.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS txt_req
OUTER APPLY (
        SELECT TOP (1) c.most_recent_sql_handle
        FROM sys.dm_exec_connections AS c
        WHERE c.session_id = s.session_id
        ORDER BY c.connect_time DESC
    ) AS conn
OUTER APPLY sys.dm_exec_sql_text(conn.most_recent_sql_handle) AS txt_conn

WHERE tst.is_user_transaction = 1
  AND s.is_user_process = 1
ORDER BY tat.transaction_begin_time ASC;

/* ===========================================================================
   COMO LER O RESULTADO

   esta_ociosa = 'SIM' e idade_minutos alto
       Transacao abandonada. O banco esta saudavel; a aplicacao e que nao
       fechou a transacao. Nao adianta reiniciar a instancia: volta amanha.

   log_usado_mb alto
       Esta e a transacao que impede o truncamento do transaction log. Veja
       por-que-o-transaction-log-esta-crescendo.md.

   estado_transacao = 'rollback em andamento'
       NAO MATE ESTA SESSAO e nao reinicie a instancia. O rollback precisa
       terminar; interromper so faz o SQL Server refazer o mesmo trabalho na
       recuperacao, geralmente demorando mais. Acompanhe o progresso com:
           KILL <spid> WITH STATUSONLY;
       (esta forma do comando apenas CONSULTA o progresso, nao mata nada)

   ANTES DE MATAR QUALQUER SESSAO, leia matar-sessao-com-seguranca.md.

   CORRECAO DEFINITIVA (aplicacao):
       - garantir Dispose/using em SqlTransaction e TransactionScope;
       - nunca chamar servico externo dentro de uma transacao aberta;
       - definir CommandTimeout compativel com o trabalho real;
       - revisar codigo que usa SET IMPLICIT_TRANSACTIONS ON.
   =========================================================================== */
