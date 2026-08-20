/* ===========================================================================
   NOME       : verificar-estatisticas-desatualizadas.sql
   OBJETIVO   : Listar as estatisticas do banco corrente ordenadas por grau de
                desatualizacao, com a taxa de amostragem usada na ultima
                atualizacao.

   COMPATIBILIDADE : SQL Server 2012 SP1+ (11.x SP1). A funcao
                     sys.dm_db_stats_properties esta disponivel a partir do
                     SQL Server 2008 R2 SP2 e do SQL Server 2012 SP1.
                     Azure SQL Database: sim.
   IMPACTO         : Nenhum. Somente leitura sobre catalogo e DMFs.
   PERMISSOES      : Ao menos uma permissao sobre a tabela (por exemplo
                     SELECT), alem de VIEW DATABASE STATE.
   TEMPO ESTIMADO  : 1 a 10 segundos, conforme a quantidade de objetos.
   ESCOPO          : BANCO CORRENTE. Execute apos USE [<BANCO>].

   AUTOR      : Fabio Cerqueira
   =========================================================================== */

SET NOCOUNT ON;

/* Ajuste conforme o volume das suas tabelas */
DECLARE @minimo_de_linhas BIGINT = 1000;

SELECT
    tabela              = QUOTENAME(SCHEMA_NAME(o.schema_id)) + '.' + QUOTENAME(o.name),
    estatistica         = st.name,
    tipo                = CASE WHEN st.auto_created  = 1 THEN 'automatica'
                               WHEN st.user_created  = 1 THEN 'manual'
                               ELSE 'do indice' END,
    tem_filtro          = st.has_filter,
    linhas_na_tabela    = sp.rows,
    linhas_amostradas   = sp.rows_sampled,
    amostragem_pct      = CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows,0) AS DECIMAL(5,2)),
    passos_no_histograma = sp.steps,
    ultima_atualizacao  = sp.last_updated,
    dias_sem_atualizar  = DATEDIFF(DAY, sp.last_updated, SYSDATETIME()),
    modificacoes        = sp.modification_counter,
    /* Este e o indicador que importa: quanto da tabela mudou desde a ultima
       atualizacao da estatistica. */
    modificacoes_pct    = CAST(100.0 * sp.modification_counter / NULLIF(sp.rows,0) AS DECIMAL(9,2)),
    avaliacao = CASE
        WHEN sp.last_updated IS NULL
            THEN 'NUNCA ATUALIZADA'
        WHEN sp.rows > 0 AND 100.0 * sp.modification_counter / sp.rows > 20
            THEN 'CRITICA - mais de 20% da tabela mudou'
        WHEN sp.rows > 0 AND 100.0 * sp.modification_counter / sp.rows > 10
            THEN 'ATENCAO - mais de 10% da tabela mudou'
        WHEN DATEDIFF(DAY, sp.last_updated, SYSDATETIME()) > 30
            THEN 'ANTIGA - mais de 30 dias'
        WHEN sp.rows > 1000000
             AND 100.0 * sp.rows_sampled / NULLIF(sp.rows,0) < 10
            THEN 'AMOSTRAGEM BAIXA em tabela grande'
        ELSE 'ok'
    END
FROM sys.stats AS st
INNER JOIN sys.objects AS o
        ON o.object_id = st.object_id
CROSS APPLY sys.dm_db_stats_properties(st.object_id, st.stats_id) AS sp
WHERE o.type = 'U'                       /* apenas tabelas de usuario */
  AND o.is_ms_shipped = 0
  AND sp.rows >= @minimo_de_linhas
ORDER BY
    CASE
        WHEN sp.last_updated IS NULL THEN 0
        WHEN sp.rows > 0 AND 100.0 * sp.modification_counter / sp.rows > 20 THEN 1
        WHEN sp.rows > 0 AND 100.0 * sp.modification_counter / sp.rows > 10 THEN 2
        ELSE 3
    END,
    sp.modification_counter DESC;

/* ---------------------------------------------------------------------------
   Configuracao de estatisticas do banco
   --------------------------------------------------------------------------- */
SELECT
    banco                       = name,
    auto_create_stats           = is_auto_create_stats_on,
    auto_update_stats           = is_auto_update_stats_on,
    auto_update_stats_async     = is_auto_update_stats_async_on,
    /* AUTO_UPDATE_STATISTICS desligado quase sempre e um erro herdado de
       recomendacao de fornecedor de ERP. Confirme antes de mexer. */
    alerta = CASE WHEN is_auto_update_stats_on = 0
                  THEN 'AUTO_UPDATE_STATISTICS DESLIGADO - verifique se ha rotina propria'
                  ELSE 'ok' END
FROM sys.databases
WHERE database_id = DB_ID();

/* ===========================================================================
   COMO ATUALIZAR (escolha consciente, nao reflexo)

   -- Uma estatistica especifica, com varredura completa:
   -- UPDATE STATISTICS dbo.<TABELA> <NOME_DA_ESTATISTICA> WITH FULLSCAN;

   -- Todas as estatisticas de uma tabela:
   -- UPDATE STATISTICS dbo.<TABELA> WITH FULLSCAN;

   -- Amostragem definida (mais barato em tabela muito grande):
   -- UPDATE STATISTICS dbo.<TABELA> WITH SAMPLE 30 PERCENT;

   -- Banco inteiro (CUIDADO: custo alto de I/O e CPU):
   -- EXEC sys.sp_updatestats;

   ATENCAO EM PRODUCAO
     - UPDATE STATISTICS WITH FULLSCAN le a tabela inteira. Em tabela grande,
       gera I/O comparavel a um SELECT completo. Faca em janela.
     - Atualizar estatistica INVALIDA os planos que dependem dela. Os planos
       serao recompilados na proxima execucao -- e isso pode gerar um pico de
       CPU logo apos a atualizacao.
     - sp_updatestats usa amostragem padrao e pode ser insuficiente em tabelas
       grandes com distribuicao desigual.
     - NAO rode sp_updatestats no meio do pico "para tentar melhorar". O custo
       da varredura costuma aprofundar o incidente.

   RELACAO COM MANUTENCAO DE INDICE
     ALTER INDEX ... REBUILD atualiza a estatistica do indice com FULLSCAN
     como efeito colateral. ALTER INDEX ... REORGANIZE NAO atualiza nada.
     Uma rotina que so faz REORGANIZE precisa atualizar estatisticas a parte.
     Veja ../indexes/manutencao-de-indices.md
   =========================================================================== */
