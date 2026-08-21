/* ===========================================================================
   NOME       : encontrar-indices-ausentes.sql
   OBJETIVO   : Listar os indices que o otimizador registrou como "teriam
                ajudado", ordenados por impacto estimado, com o comando
                CREATE INDEX ja montado para revisao.

   COMPATIBILIDADE : SQL Server 2012+ (11.x). Azure SQL Database: sim.
   IMPACTO         : Nenhum para consultar. ALTO para aplicar.
   PERMISSOES      : VIEW SERVER STATE.
   TEMPO ESTIMADO  : < 3 segundos.
   ESCOPO          : Filtra pelo banco corrente. Execute apos USE [<BANCO>].

   ============================ LEIA ANTES DE APLICAR ======================

   ESTE SCRIPT NAO DIZ QUAIS INDICES CRIAR. Ele diz quais indices o otimizador
   IMAGINOU que ajudariam, uma query de cada vez, sem consciencia:

     - dos indices que ja existem na tabela;
     - das outras sugestoes desta mesma lista;
     - do custo de escrita que voce vai pagar;
     - da ordem ideal das colunas (a sugestao apenas separa igualdade de
       desigualdade -- NAO e uma ordem otimizada por seletividade);
     - do espaco em disco e em memoria.

   APLICAR A LISTA INTEIRA EM BLOCO E UM DOS ERROS MAIS CAROS QUE EXISTEM em
   administracao de SQL Server: cria-se uma pilha de indices sobrepostos que
   penaliza toda escrita e nao entrega a leitura prometida.

   USE COMO PISTA, NUNCA COMO RECEITA.

   =========================================================================

   AUTOR      : Fabio Cerqueira
   =========================================================================== */

SET NOCOUNT ON;

/* Uptime primeiro: sem ele, nada aqui e conclusivo. */
SELECT
    inicio_da_instancia = sqlserver_start_time,
    uptime_horas        = DATEDIFF(HOUR, sqlserver_start_time, SYSDATETIME()),
    representativo      = CASE
        WHEN DATEDIFF(HOUR, sqlserver_start_time, SYSDATETIME()) < 168
        THEN 'NAO - menos de 7 dias. Considere o ciclo de negocio antes de decidir.'
        ELSE 'razoavel' END
FROM sys.dm_os_sys_info;


/* ---------------------------------------------------------------------------
   Sugestoes ordenadas por impacto estimado
   --------------------------------------------------------------------------- */
SELECT TOP (30)
    /* Metrica composta usual: custo medio x impacto percentual x frequencia.
       E uma ESTIMATIVA relativa, util so para ordenar a lista. */
    impacto_estimado    = CONVERT(DECIMAL(28,2),
                            migs.avg_total_user_cost
                            * migs.avg_user_impact
                            * (migs.user_seeks + migs.user_scans)),
    tabela              = mid.statement,
    ganho_pct_estimado  = CONVERT(DECIMAL(5,2), migs.avg_user_impact),
    custo_medio_query   = CONVERT(DECIMAL(18,4), migs.avg_total_user_cost),
    seeks               = migs.user_seeks,
    scans               = migs.user_scans,
    ultima_ocorrencia   = migs.last_user_seek,
    compilacoes         = migs.unique_compiles,

    colunas_igualdade   = mid.equality_columns,
    colunas_desigualdade = mid.inequality_columns,
    colunas_incluidas   = mid.included_columns,

    /* Comando montado PARA REVISAO. Ajuste o nome e, principalmente, revise a
       ORDEM das colunas-chave antes de executar. */
    comando_para_revisar =
        'CREATE NONCLUSTERED INDEX [IX_'
        + REPLACE(REPLACE(REPLACE(
              RIGHT(mid.statement, CHARINDEX('.', REVERSE(mid.statement)) - 1),
              '[',''),']',''),' ','_')
        + '_' + CONVERT(VARCHAR(20), mig.index_handle) + ']'
        + ' ON ' + mid.statement + ' ('
        + ISNULL(mid.equality_columns, '')
        + CASE WHEN mid.equality_columns IS NOT NULL
                AND mid.inequality_columns IS NOT NULL THEN ', ' ELSE '' END
        + ISNULL(mid.inequality_columns, '')
        + ')'
        + ISNULL(' INCLUDE (' + mid.included_columns + ')', '')
        + ' WITH (ONLINE = OFF, FILLFACTOR = 90); -- revisar antes de executar',

    /* Quantos indices a tabela JA tem. Numero alto = pense duas vezes. */
    indices_existentes_na_tabela =
        (SELECT COUNT(*)
         FROM sys.indexes AS i
         WHERE i.object_id = mid.object_id
           AND i.type IN (1, 2)
           AND i.is_hypothetical = 0),

    alerta = CASE
        WHEN (SELECT COUNT(*) FROM sys.indexes AS i
              WHERE i.object_id = mid.object_id AND i.type IN (1,2)
                AND i.is_hypothetical = 0) >= 8
            THEN 'TABELA JA MUITO INDEXADA - avaliar consolidar em vez de criar'
        WHEN migs.user_seeks + migs.user_scans < 100
            THEN 'POUCAS OCORRENCIAS - pode ser query pontual, nao vale um indice'
        WHEN migs.avg_user_impact < 50
            THEN 'GANHO ESTIMADO BAIXO'
        ELSE 'candidato razoavel - ainda assim, revise manualmente'
    END

FROM sys.dm_db_missing_index_group_stats AS migs
INNER JOIN sys.dm_db_missing_index_groups AS mig
        ON mig.index_group_handle = migs.group_handle
INNER JOIN sys.dm_db_missing_index_details AS mid
        ON mid.index_handle = mig.index_handle
WHERE mid.database_id = DB_ID()
ORDER BY impacto_estimado DESC;

/* ===========================================================================
   COMO USAR ESTA SAIDA DE FORMA RESPONSAVEL

   1. VERIFIQUE O QUE JA EXISTE
      Antes de criar, veja os indices atuais da tabela. Muitas vezes a sugestao
      pode ser atendida acrescentando colunas ao INCLUDE de um indice existente
      -- o que custa muito menos que um indice novo.

      SELECT i.name, i.type_desc, i.is_unique,
             chave = STUFF((SELECT ', ' + c.name
                            FROM sys.index_columns ic
                            JOIN sys.columns c ON c.object_id = ic.object_id
                                              AND c.column_id = ic.column_id
                            WHERE ic.object_id = i.object_id
                              AND ic.index_id  = i.index_id
                              AND ic.is_included_column = 0
                            ORDER BY ic.key_ordinal
                            FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'),1,2,'')
      FROM sys.indexes AS i
      WHERE i.object_id = OBJECT_ID('<ESQUEMA>.<TABELA>')
        AND i.type IN (1,2);

   2. CONSOLIDE AS SUGESTOES DA MESMA TABELA
      Tres sugestoes para a mesma tabela quase sempre podem virar UM indice
      bem desenhado. Nao crie tres.

   3. REVISE A ORDEM DAS COLUNAS-CHAVE
      A sugestao apenas coloca as colunas de igualdade antes das de
      desigualdade. Isso NAO e uma ordem otimizada. Como regra de trabalho:
      colunas de igualdade primeiro, as mais seletivas antes, e a coluna de
      desigualdade (intervalo) por ultimo entre as chaves.

   4. CUIDADO COM INCLUDE GIGANTE
      Sugestoes com 15 colunas incluidas produzem indices quase do tamanho da
      tabela. Avalie se a query realmente precisa de todas essas colunas.

   5. MECA ANTES E DEPOIS
      Guarde as leituras logicas da query antes de criar o indice. Se nao
      melhorou, REMOVA o indice -- ele continuara custando escrita para sempre.

   6. CRIE EM JANELA
      CREATE INDEX em tabela grande bloqueia. ONLINE = ON reduz o bloqueio, mas
      exige Enterprise (ou SQL Server 2019+ em edicoes que o suportem), consome
      mais tempo, mais log e mais tempdb. Verifique a edicao antes.

   NOTA SOBRE O INDICE CLUSTERIZADO
      Estas sugestoes sao sempre de indices NAO clusterizados. A escolha do
      indice clusterizado e uma decisao de modelagem, nao de ajuste fino.
   =========================================================================== */
