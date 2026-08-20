/* ===========================================================================
   NOME       : analisar-uso-do-tempdb.sql
   OBJETIVO   : Descobrir QUEM esta consumindo o tempdb e por que ele cresceu:
                objetos de usuario, objetos internos (sort, hash, spill) ou
                version store.

   COMPATIBILIDADE : SQL Server 2012+ (11.x).
                     Azure SQL Database: parcial.
   IMPACTO         : Nenhum. Somente leitura sobre DMVs.
   PERMISSOES      : VIEW SERVER STATE.
   TEMPO ESTIMADO  : < 3 segundos.

   AUTOR      : Fabio Cerqueira
   =========================================================================== */

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

/* ---------------------------------------------------------------------------
   BLOCO 1 - Quem esta ocupando o tempdb, por categoria
   E esta a divisao que direciona toda a investigacao.
   --------------------------------------------------------------------------- */
SELECT
    total_mb              = SUM(total_page_count)                    * 8 / 1024.0,
    livre_mb              = SUM(unallocated_extent_page_count)       * 8 / 1024.0,
    objetos_de_usuario_mb = SUM(user_object_reserved_page_count)     * 8 / 1024.0,
    objetos_internos_mb   = SUM(internal_object_reserved_page_count) * 8 / 1024.0,
    version_store_mb      = SUM(version_store_reserved_page_count)   * 8 / 1024.0,
    percentual_livre      = CASE WHEN SUM(total_page_count) = 0 THEN 0
                                 ELSE 100.0 * SUM(unallocated_extent_page_count)
                                            / SUM(total_page_count) END
FROM tempdb.sys.dm_db_file_space_usage;


/* ---------------------------------------------------------------------------
   BLOCO 2 - Configuracao dos arquivos do tempdb
   Numero de arquivos de dados e uniformidade de tamanho importam para
   contencao de alocacao.
   --------------------------------------------------------------------------- */
SELECT
    arquivo_logico  = mf.name,
    tipo            = mf.type_desc,
    arquivo_fisico  = mf.physical_name,
    tamanho_mb      = mf.size * 8.0 / 1024,
    crescimento     = CASE WHEN mf.is_percent_growth = 1
                           THEN CAST(mf.growth AS VARCHAR(10)) + ' %'
                           ELSE CAST(mf.growth * 8.0 / 1024 AS VARCHAR(20)) + ' MB' END,
    alerta          = CASE WHEN mf.is_percent_growth = 1
                           THEN 'ATENCAO: crescimento percentual em tempdb causa arquivos desiguais'
                           ELSE 'ok' END
FROM tempdb.sys.database_files AS mf
ORDER BY mf.type_desc, mf.file_id;


/* ---------------------------------------------------------------------------
   BLOCO 3 - Sessoes que mais consomem tempdb AGORA
   Espaco alocado por tarefa em execucao.
   --------------------------------------------------------------------------- */
SELECT TOP (20)
    ts.session_id,
    ts.request_id,
    usuario_alocado_mb  = (ts.user_objects_alloc_page_count
                           - ts.user_objects_dealloc_page_count) * 8 / 1024.0,
    interno_alocado_mb  = (ts.internal_objects_alloc_page_count
                           - ts.internal_objects_dealloc_page_count) * 8 / 1024.0,
    total_mb            = (ts.user_objects_alloc_page_count
                           - ts.user_objects_dealloc_page_count
                           + ts.internal_objects_alloc_page_count
                           - ts.internal_objects_dealloc_page_count) * 8 / 1024.0,
    s.login_name,
    s.host_name,
    s.program_name,
    r.status,
    r.command,
    banco               = DB_NAME(r.database_id),
    comando             = t.text
FROM sys.dm_db_task_space_usage AS ts
LEFT JOIN sys.dm_exec_sessions AS s
       ON s.session_id = ts.session_id
LEFT JOIN sys.dm_exec_requests AS r
       ON r.session_id = ts.session_id
      AND r.request_id = ts.request_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE ts.session_id > 50
  AND (ts.user_objects_alloc_page_count + ts.internal_objects_alloc_page_count) > 0
ORDER BY total_mb DESC;


/* ---------------------------------------------------------------------------
   BLOCO 4 - Contencao de alocacao (PAGELATCH em paginas de sistema)
   Recursos 2:1:1 (PFS), 2:1:3 (SGAM) e 2:1:2 (GAM) indicam contencao classica
   de tempdb, resolvida com mais arquivos de dados do mesmo tamanho.
   --------------------------------------------------------------------------- */
SELECT
    r.session_id,
    r.wait_type,
    r.wait_resource,
    espera_ms   = r.wait_time,
    r.status,
    r.command,
    diagnostico = CASE
        WHEN r.wait_resource LIKE '2:%:1' THEN 'Contencao de PFS no tempdb'
        WHEN r.wait_resource LIKE '2:%:2' THEN 'Contencao de GAM no tempdb'
        WHEN r.wait_resource LIKE '2:%:3' THEN 'Contencao de SGAM no tempdb'
        ELSE 'outro'
    END
FROM sys.dm_exec_requests AS r
WHERE r.wait_type LIKE 'PAGELATCH%'
  AND r.wait_resource LIKE '2:%';

/* ===========================================================================
   COMO LER O RESULTADO E O QUE FAZER

   version_store_mb ALTO
       Ha isolamento de versao de linha ativo (RCSI ou SNAPSHOT) e uma
       transacao ANTIGA impedindo a limpeza das versoes.
       Correcao: encontrar e encerrar a transacao antiga --
       encontrar-transacoes-abertas-longa-duracao.sql
       O tempdb nao vai parar de crescer enquanto ela existir.

   objetos_internos_mb ALTO
       Sort e hash que nao couberam na memoria concedida (SPILL TO TEMPDB).
       Correcao: e um problema de ESTIMATIVA, nao de tempdb. Atualize
       estatisticas e revise indices --
       ../performance/estatisticas-desatualizadas.md

   objetos_de_usuario_mb ALTO
       Tabelas temporarias e variaveis de tabela grandes. Revise o codigo:
       #tabelas que carregam milhoes de linhas sem necessidade, procedures
       que nao dao DROP explicito em lote longo.

   BLOCO 4 com linhas
       Contencao de alocacao. Correcao classica: multiplos arquivos de DADOS
       no tempdb, TODOS DO MESMO TAMANHO e com o MESMO incremento de
       crescimento. Regra pratica difundida: um arquivo por core ate 8 cores;
       acima disso, avaliar aumentos graduais. A partir do SQL Server 2016 o
       instalador ja sugere essa configuracao e alguns comportamentos que
       antes exigiam trace flags 1117/1118 passaram a ser padrao no tempdb.

   ERRO COMUM
       Aumentar o tempdb sem descobrir a categoria de consumo. O arquivo
       cresce, o problema volta na semana seguinte.
   =========================================================================== */
