/* ===========================================================================
   NOME       : analisar-fragmentacao.sql
   OBJETIVO   : Medir a fragmentacao dos indices e indicar, para cada um, se
                vale REORGANIZE, REBUILD ou nada.

   COMPATIBILIDADE : SQL Server 2012+ (11.x). Azure SQL Database: sim.
   IMPACTO         : DEPENDE DO MODO DE VARREDURA (veja abaixo).
                     LIMITED  -> baixo, seguro em producao (padrao aqui)
                     SAMPLED  -> medio
                     DETAILED -> ALTO: le todas as paginas de todos os niveis
                                 do indice. NAO use em producao no horario de
                                 pico em bases grandes.
   PERMISSOES      : VIEW DATABASE STATE.
   TEMPO ESTIMADO  : segundos (LIMITED) a muitos minutos (DETAILED).
   ESCOPO          : BANCO CORRENTE. Execute apos USE [<BANCO>].

   ATENCAO    : fragmentacao e o problema de indice MAIS SUPERESTIMADO do SQL
                Server. Em armazenamento moderno (SSD/NVMe) e com os dados no
                buffer pool, o impacto da fragmentacao externa e pequeno --
                muito menor que o de uma estatistica desatualizada ou de um
                indice ausente.

                Antes de montar uma rotina pesada de REBUILD, leia
                manutencao-de-indices.md.

   AUTOR      : Fabio Cerqueira
   =========================================================================== */

SET NOCOUNT ON;

/* Modo de varredura. Mantenha LIMITED em producao.
   Troque para 'SAMPLED' apenas se precisar de avg_page_space_used_in_percent
   (densidade de pagina), e de preferencia em janela. */
DECLARE @modo SYSNAME = N'LIMITED';

/* Indices pequenos nao valem manutencao: abaixo de ~1000 paginas (8 MB) o
   indice tende a ocupar extensoes mistas e a fragmentacao medida e ruido. */
DECLARE @minimo_de_paginas INT = 1000;

SELECT
    tabela            = QUOTENAME(SCHEMA_NAME(o.schema_id)) + '.' + QUOTENAME(o.name),
    indice            = i.name,
    tipo              = i.type_desc,
    ips.partition_number,
    fragmentacao_pct  = CAST(ips.avg_fragmentation_in_percent AS DECIMAL(5,2)),
    paginas           = ips.page_count,
    tamanho_mb        = CAST(ips.page_count * 8.0 / 1024 AS DECIMAL(18,2)),
    registros         = ips.record_count,
    nivel_do_indice   = ips.index_level,

    recomendacao = CASE
        WHEN ips.page_count < @minimo_de_paginas
            THEN 'IGNORAR - indice pequeno demais para que a medida signifique algo'
        WHEN ips.avg_fragmentation_in_percent < 10
            THEN 'NADA A FAZER'
        WHEN ips.avg_fragmentation_in_percent < 30
            THEN 'REORGANIZE (online, incremental, interrompivel)'
        ELSE 'REBUILD (mais caro, mas recria o indice e as estatisticas)'
    END,

    comando_para_revisar = CASE
        WHEN ips.page_count < @minimo_de_paginas THEN NULL
        WHEN ips.avg_fragmentation_in_percent < 10 THEN NULL
        WHEN ips.avg_fragmentation_in_percent < 30
            THEN 'ALTER INDEX ' + QUOTENAME(i.name) + ' ON '
                 + QUOTENAME(SCHEMA_NAME(o.schema_id)) + '.' + QUOTENAME(o.name)
                 + ' REORGANIZE;'
        ELSE 'ALTER INDEX ' + QUOTENAME(i.name) + ' ON '
             + QUOTENAME(SCHEMA_NAME(o.schema_id)) + '.' + QUOTENAME(o.name)
             + ' REBUILD WITH (ONLINE = OFF, SORT_IN_TEMPDB = ON, FILLFACTOR = 90);'
             + ' -- ONLINE = ON exige edicao compativel'
    END,

    /* Contexto que muda a decisao: um indice muito fragmentado que ninguem le
       nao precisa de manutencao -- precisa ser removido. */
    leituras_desde_restart = ISNULL(ius.user_seeks,0) + ISNULL(ius.user_scans,0)
                             + ISNULL(ius.user_lookups,0),
    manutencoes_desde_restart = ISNULL(ius.user_updates, 0),
    observacao = CASE
        WHEN ips.page_count >= @minimo_de_paginas
         AND ISNULL(ius.user_seeks,0) + ISNULL(ius.user_scans,0)
           + ISNULL(ius.user_lookups,0) = 0
            THEN 'ESTE INDICE NAO E LIDO. Antes de reconstruir, avalie remover.'
        ELSE NULL
    END

FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, @modo) AS ips
INNER JOIN sys.indexes AS i
        ON i.object_id = ips.object_id
       AND i.index_id  = ips.index_id
INNER JOIN sys.objects AS o
        ON o.object_id = i.object_id
LEFT JOIN sys.dm_db_index_usage_stats AS ius
       ON ius.object_id   = i.object_id
      AND ius.index_id    = i.index_id
      AND ius.database_id = DB_ID()
WHERE o.type = 'U'
  AND o.is_ms_shipped = 0
  AND i.index_id > 0                 /* ignora heaps */
  AND ips.index_level = 0            /* apenas o nivel folha */
  AND ips.page_count >= @minimo_de_paginas
ORDER BY ips.avg_fragmentation_in_percent DESC, ips.page_count DESC;

/* ===========================================================================
   COMO LER E O QUE FAZER

   OS LIMIARES 5% / 30%
       Os valores de 5% (fazer nada) e 30% (REBUILD) vem de uma orientacao
       antiga da Microsoft e viraram tradicao. Sao PONTO DE PARTIDA, nao lei.
       Este script usa 10% como piso pratico para reduzir manutencao inutil.
       Calibre com a sua carga: o que importa e o efeito medido nas queries,
       nao o numero da coluna de fragmentacao.

   POR QUE IGNORAR INDICES PEQUENOS
       Indices com menos de ~1000 paginas costumam ocupar extensoes mistas.
       A fragmentacao medida neles e alta por construcao e nao tem efeito
       pratico. Reconstrui-los e trabalho jogado fora.

   REORGANIZE x REBUILD (resumo -- detalhes em manutencao-de-indices.md)

     REORGANIZE
       - sempre online; pode ser interrompido sem perder o trabalho ja feito;
       - usa menos transaction log;
       - NAO atualiza estatisticas;
       - desfragmenta apenas o nivel folha.

     REBUILD
       - recria o indice do zero;
       - ATUALIZA as estatisticas do indice com FULLSCAN, de graca;
       - ONLINE = OFF bloqueia a tabela durante a operacao;
       - ONLINE = ON reduz o bloqueio, mas exige edicao compativel, consome
         mais tempo, mais log e mais tempdb;
       - gera MUITO transaction log: em recovery model FULL, um REBUILD de
         tabela grande pode encher o disco de log.

   ARMADILHA CLASSICA
       Uma rotina que so faz REORGANIZE nao atualiza estatistica nenhuma. Se a
       sua manutencao evoluiu de REBUILD para REORGANIZE em algum momento e
       ninguem acrescentou um passo de UPDATE STATISTICS, o banco esta ha anos
       sem atualizar estatisticas de indice pela rotina.
       Veja ../performance/estatisticas-desatualizadas.md

   O QUE VALE MAIS QUE DESFRAGMENTAR
       1. estatisticas atualizadas;
       2. remover indices duplicados e nao utilizados;
       3. corrigir predicados nao SARGable;
       4. criar o indice que realmente falta.
       Fragmentacao vem depois de tudo isso na ordem de prioridade.
   =========================================================================== */
