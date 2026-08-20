/* ===========================================================================
   NOME       : encontrar-indices-nao-utilizados.sql
   OBJETIVO   : Encontrar indices que custam escrita, espaco e manutencao sem
                servir nenhuma leitura -- e tambem os que servem pouca leitura
                para muita escrita.

   COMPATIBILIDADE : SQL Server 2012+ (11.x). Azure SQL Database: sim.
   IMPACTO         : Nenhum para consultar. ALTO e IRREVERSIVEL para aplicar.
   PERMISSOES      : VIEW SERVER STATE e VIEW DEFINITION.
   TEMPO ESTIMADO  : < 5 segundos.
   ESCOPO          : BANCO CORRENTE. Execute apos USE [<BANCO>].

   ATENCAO PRINCIPAL : sys.dm_db_index_usage_stats ZERA NO RESTART DA
                INSTANCIA. Um indice que atende exclusivamente ao fechamento
                mensal, ao balanco anual ou a um relatorio trimestral parece
                inutil em uma janela de duas semanas.

                REGRA: nao remova indice com base em uptime menor que um
                CICLO COMPLETO DE NEGOCIO da sua empresa.

   AUTOR      : Fabio Cerqueira
   =========================================================================== */

SET NOCOUNT ON;

/* Uptime primeiro. Sem isso, este script nao deve ser usado para decidir nada. */
SELECT
    inicio_da_instancia = sqlserver_start_time,
    uptime_dias         = DATEDIFF(DAY, sqlserver_start_time, SYSDATETIME()),
    veredito = CASE
        WHEN DATEDIFF(DAY, sqlserver_start_time, SYSDATETIME()) < 30
            THEN 'NAO REMOVA NADA - menos de 30 dias de estatistica acumulada'
        WHEN DATEDIFF(DAY, sqlserver_start_time, SYSDATETIME()) < 90
            THEN 'CUIDADO - considere fechamentos mensais e trimestrais'
        ELSE 'janela razoavel - ainda assim, confira o ciclo anual'
    END
FROM sys.dm_os_sys_info;


/* ---------------------------------------------------------------------------
   BLOCO 1 - Indices NUNCA lidos desde o restart
   O LEFT JOIN e essencial: um indice jamais utilizado nao tem linha alguma
   em sys.dm_db_index_usage_stats.
   --------------------------------------------------------------------------- */
SELECT
    tabela          = QUOTENAME(SCHEMA_NAME(o.schema_id)) + '.' + QUOTENAME(o.name),
    indice          = i.name,
    tipo            = i.type_desc,
    i.is_unique,
    i.is_primary_key,
    i.is_disabled,
    linhas          = p.linhas,
    tamanho_mb      = p.tamanho_mb,

    leituras_seek   = ISNULL(ius.user_seeks, 0),
    leituras_scan   = ISNULL(ius.user_scans, 0),
    lookups         = ISNULL(ius.user_lookups, 0),
    leituras_totais = ISNULL(ius.user_seeks,0) + ISNULL(ius.user_scans,0)
                      + ISNULL(ius.user_lookups,0),
    /* user_updates conta as MANUTENCOES que este indice sofreu.
       E o custo que voce paga por ele. */
    manutencoes     = ISNULL(ius.user_updates, 0),

    situacao = CASE
        WHEN ius.index_id IS NULL
            THEN 'NUNCA TOCADO desde o restart (nem leitura nem escrita registrada)'
        WHEN ISNULL(ius.user_seeks,0) + ISNULL(ius.user_scans,0)
           + ISNULL(ius.user_lookups,0) = 0
            THEN 'SO ESCRITA - custa manutencao e nunca serviu leitura'
        ELSE 'tem leitura'
    END,

    ultima_leitura = (SELECT MAX(v)
                      FROM (VALUES (ius.last_user_seek),
                                   (ius.last_user_scan),
                                   (ius.last_user_lookup)) AS t(v)),

    comando_para_revisar =
        'DROP INDEX ' + QUOTENAME(i.name) + ' ON '
        + QUOTENAME(SCHEMA_NAME(o.schema_id)) + '.' + QUOTENAME(o.name)
        + '; -- CONFIRMAR ciclo de negocio antes de executar'

FROM sys.indexes AS i
INNER JOIN sys.objects AS o
        ON o.object_id = i.object_id
LEFT JOIN sys.dm_db_index_usage_stats AS ius
       ON ius.object_id   = i.object_id
      AND ius.index_id    = i.index_id
      AND ius.database_id = DB_ID()
CROSS APPLY (
        SELECT linhas     = SUM(CASE WHEN ps.index_id IN (0,1) THEN ps.row_count ELSE 0 END),
               tamanho_mb = CAST(SUM(ps.used_page_count) * 8.0 / 1024 AS DECIMAL(18,2))
        FROM sys.dm_db_partition_stats AS ps
        WHERE ps.object_id = i.object_id
          AND ps.index_id  = i.index_id
    ) AS p
WHERE o.type = 'U'
  AND o.is_ms_shipped = 0
  AND i.type = 2                      /* apenas nao clusterizados */
  AND i.is_primary_key = 0            /* nunca sugerir remover PK */
  AND i.is_unique_constraint = 0      /* nem constraint de unicidade */
  AND (ius.index_id IS NULL
       OR ISNULL(ius.user_seeks,0) + ISNULL(ius.user_scans,0)
        + ISNULL(ius.user_lookups,0) = 0)
ORDER BY p.tamanho_mb DESC;


/* ---------------------------------------------------------------------------
   BLOCO 2 - Indices com escrita MUITO maior que leitura
   Nao sao inuteis, mas talvez nao valham o que custam.
   --------------------------------------------------------------------------- */
SELECT
    tabela          = QUOTENAME(SCHEMA_NAME(o.schema_id)) + '.' + QUOTENAME(o.name),
    indice          = i.name,
    leituras_totais = ius.user_seeks + ius.user_scans + ius.user_lookups,
    manutencoes     = ius.user_updates,
    proporcao_escrita_leitura =
        CAST(ius.user_updates * 1.0
             / NULLIF(ius.user_seeks + ius.user_scans + ius.user_lookups, 0)
             AS DECIMAL(18,2)),
    tamanho_mb      = p.tamanho_mb,
    ius.last_user_seek,
    ius.last_user_scan,
    avaliacao = CASE
        WHEN ius.user_updates * 1.0
             / NULLIF(ius.user_seeks + ius.user_scans + ius.user_lookups,0) > 100
            THEN 'MAIS DE 100 ESCRITAS POR LEITURA - forte candidato a remocao'
        WHEN ius.user_updates * 1.0
             / NULLIF(ius.user_seeks + ius.user_scans + ius.user_lookups,0) > 20
            THEN 'desproporcional - avaliar'
        ELSE 'aceitavel'
    END
FROM sys.indexes AS i
INNER JOIN sys.objects AS o
        ON o.object_id = i.object_id
INNER JOIN sys.dm_db_index_usage_stats AS ius
        ON ius.object_id   = i.object_id
       AND ius.index_id    = i.index_id
       AND ius.database_id = DB_ID()
CROSS APPLY (
        SELECT tamanho_mb = CAST(SUM(ps.used_page_count) * 8.0 / 1024 AS DECIMAL(18,2))
        FROM sys.dm_db_partition_stats AS ps
        WHERE ps.object_id = i.object_id
          AND ps.index_id  = i.index_id
    ) AS p
WHERE o.type = 'U'
  AND o.is_ms_shipped = 0
  AND i.type = 2
  AND i.is_primary_key = 0
  AND i.is_unique_constraint = 0
  AND ius.user_updates > 0
  AND (ius.user_seeks + ius.user_scans + ius.user_lookups) > 0
  AND ius.user_updates * 1.0
      / NULLIF(ius.user_seeks + ius.user_scans + ius.user_lookups, 0) > 20
ORDER BY proporcao_escrita_leitura DESC;

/* ===========================================================================
   PROCEDIMENTO SEGURO PARA REMOVER UM INDICE

   1. GUARDE A DEFINICAO COMPLETA antes de remover. Sem ela, recriar exige
      redescobrir colunas, ordem, INCLUDE, filtro e fillfactor.

   2. DESABILITE EM VEZ DE REMOVER (reversivel, sem perder a definicao):

        ALTER INDEX <INDICE> ON <ESQUEMA>.<TABELA> DISABLE;

      O indice para de ser mantido e para de ocupar espaco de dados, mas a
      DEFINICAO permanece no catalogo. Se algo quebrar:

        ALTER INDEX <INDICE> ON <ESQUEMA>.<TABELA> REBUILD;

      ATENCAO: desabilitar o indice CLUSTERIZADO torna a TABELA INTEIRA
      inacessivel. Este script so lista nao clusterizados justamente por isso.

   3. OBSERVE POR UM CICLO DE NEGOCIO COMPLETO.

   4. SO ENTAO remova de vez.

   O QUE NUNCA REMOVER SEM ANALISE MUITO CUIDADOSA
     - indices que sustentam PRIMARY KEY ou UNIQUE (regra de integridade, nao
       otimizacao). Este script ja os exclui;
     - indices usados por FOREIGN KEY: sem eles, DELETE no pai varre o filho;
     - indices filtrados criados para uma rotina especifica;
     - indices de ferramentas ou ERP de terceiros -- pode quebrar suporte.
   =========================================================================== */
