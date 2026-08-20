/* ===========================================================================
   NOME       : quem-esta-bloqueando-quem.sql
   OBJETIVO   : Mostrar cada par bloqueador -> bloqueado com contexto completo
                dos DOIS lados: login, host, programa, comando e, o mais
                importante, o TEXTO da query do bloqueador -- inclusive quando
                ele esta 'sleeping' com uma transacao aberta e esquecida.

   COMPATIBILIDADE : SQL Server 2012+ (11.x). Azure SQL Database: sim.
   IMPACTO         : Nenhum. Somente leitura sobre DMVs.
   PERMISSOES      : VIEW SERVER STATE.
   TEMPO ESTIMADO  : < 2 segundos.

   ATENCAO    : A cadeia de bloqueio muda de segundo a segundo. SALVE A SAIDA
                EM ARQUIVO antes de qualquer acao corretiva -- depois de matar
                a sessao nao ha como reconstruir esta informacao.

   POR QUE ESTE SCRIPT E NAO sp_who2 : sp_who2 informa QUEM bloqueia, mas nao
                mostra o texto da query do bloqueador nem distingue sessao
                ativa de sessao dormindo com transacao aberta -- que e
                exatamente a informacao que resolve o incidente.

   AUTOR      : Fabio Cerqueira
   =========================================================================== */

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

SELECT
    /* ---------- quem esta bloqueando ---------- */
    bloqueador_spid            = bloqueador.session_id,
    bloqueador_status          = bloqueador.status,
    bloqueador_login           = bloqueador.login_name,
    bloqueador_host            = bloqueador.host_name,
    bloqueador_programa        = bloqueador.program_name,
    bloqueador_ultimo_comando  = bloqueador.last_request_end_time,
    bloqueador_transacoes      = bloqueador.open_transaction_count,

    /* Este e o diagnostico que resolve a maior parte dos casos:
       sessao dormindo + transacao aberta = defeito na aplicacao, nao no banco. */
    diagnostico = CASE
                      WHEN bloqueador.status = 'sleeping'
                       AND bloqueador.open_transaction_count > 0
                          THEN 'TRANSACAO ABERTA E ABANDONADA PELA APLICACAO'
                      WHEN bloqueador.status = 'sleeping'
                          THEN 'Sessao ociosa - verificar transacao implicita'
                      WHEN req_bloqueador.session_id IS NOT NULL
                          THEN 'Bloqueador em execucao - otimizar a query dele'
                      ELSE 'Verificar manualmente'
                  END,

    bloqueador_texto = COALESCE(txt_req_bloq.text, txt_conn_bloq.text),

    /* ---------- quem esta sofrendo ---------- */
    vitima_spid       = r.session_id,
    vitima_esperando_seg = r.wait_time / 1000,
    vitima_wait_type  = r.wait_type,
    vitima_recurso    = r.wait_resource,
    vitima_login      = vitima.login_name,
    vitima_host       = vitima.host_name,
    vitima_programa   = vitima.program_name,
    vitima_banco      = DB_NAME(r.database_id),
    vitima_texto      = SUBSTRING(
                            txt_vitima.text,
                            (r.statement_start_offset / 2) + 1,
                            ((CASE r.statement_end_offset
                                  WHEN -1 THEN DATALENGTH(txt_vitima.text)
                                  ELSE r.statement_end_offset
                              END - r.statement_start_offset) / 2) + 1)

FROM sys.dm_exec_requests AS r

/* a sessao que esta esperando */
INNER JOIN sys.dm_exec_sessions AS vitima
        ON vitima.session_id = r.session_id

/* a sessao que esta bloqueando */
LEFT JOIN sys.dm_exec_sessions AS bloqueador
       ON bloqueador.session_id = r.blocking_session_id

/* se o bloqueador estiver executando algo, pegamos a query atual dele */
LEFT JOIN sys.dm_exec_requests AS req_bloqueador
       ON req_bloqueador.session_id = r.blocking_session_id

OUTER APPLY sys.dm_exec_sql_text(req_bloqueador.sql_handle) AS txt_req_bloq

/* se o bloqueador estiver 'sleeping', nao ha request -- recuperamos o ULTIMO
   comando executado por ele via sys.dm_exec_connections. E este comando que
   normalmente revela a transacao que ficou aberta. */
OUTER APPLY (
        SELECT TOP (1) c.most_recent_sql_handle
        FROM sys.dm_exec_connections AS c
        WHERE c.session_id = r.blocking_session_id
        ORDER BY c.connect_time DESC
    ) AS conn_bloq
OUTER APPLY sys.dm_exec_sql_text(conn_bloq.most_recent_sql_handle) AS txt_conn_bloq

OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS txt_vitima

WHERE r.blocking_session_id <> 0
  AND r.blocking_session_id <> r.session_id   /* auto-bloqueio por paralelismo */
ORDER BY r.wait_time DESC;

/* ===========================================================================
   COMO LER O RESULTADO

   diagnostico = 'TRANSACAO ABERTA E ABANDONADA PELA APLICACAO'
       O banco esta saudavel. A aplicacao abriu uma transacao e nao deu COMMIT
       nem ROLLBACK. Causas tipicas:
         - TransactionScope ou SqlTransaction sem Dispose em caminho de excecao
         - chamada a servico externo lento DENTRO da transacao
         - CommandTimeout estourado na aplicacao sem rollback explicito
         - alguem abriu BEGIN TRAN no SSMS e saiu para almocar
       Confirme a idade com encontrar-transacoes-abertas-longa-duracao.sql.

   diagnostico = 'Bloqueador em execucao'
       O bloqueador esta trabalhando de verdade. A correcao e otimizar a query
       dele (indice, plano, volume), nao mata-lo repetidamente.

   vitima_wait_type comeca com LCK_M_
       Confirma bloqueio por lock. LCK_M_X = espera por lock exclusivo,
       LCK_M_S = espera por lock compartilhado, LCK_M_U = por update lock.

   Muitas vitimas para um unico bloqueador
       Use arvore-de-bloqueio-hierarquica.sql para achar a raiz da cadeia.
       NUNCA mate uma vitima intermediaria: mate a raiz, e so depois de ler
       matar-sessao-com-seguranca.md.
   =========================================================================== */
