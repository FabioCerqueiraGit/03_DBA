/* ===========================================================================
   NOME       : espaco-em-disco-e-arquivos-do-banco.sql
   OBJETIVO   : Responder de uma vez: quanto espaco resta em cada volume,
                qual o tamanho e o espaco livre interno de cada arquivo de
                banco, e qual a latencia real de I/O por arquivo.

   COMPATIBILIDADE : SQL Server 2012+ (11.x).
                     sys.dm_os_volume_stats: SQL Server 2008 R2 SP1+.
                     Azure SQL Database: parcial.
   IMPACTO         : Baixo. O BLOCO 2 percorre todos os bancos com
                     sp_MSforeachdb (procedure NAO DOCUMENTADA da Microsoft);
                     em instancias com centenas de bancos pode levar alguns
                     segundos.
   PERMISSOES      : VIEW SERVER STATE. Para sys.dm_os_volume_stats e
                     necessario tambem VIEW ANY DEFINITION.
   TEMPO ESTIMADO  : 2 a 15 segundos.

   AUTOR      : Fabio Cerqueira
   =========================================================================== */

SET NOCOUNT ON;

/* ---------------------------------------------------------------------------
   BLOCO 1 - Espaco livre por VOLUME (disco fisico)
   E a primeira coisa a olhar quando o alerta e "disco cheio".
   --------------------------------------------------------------------------- */
SELECT DISTINCT
    volume            = vs.volume_mount_point,
    rotulo            = vs.logical_volume_name,
    sistema_arquivos  = vs.file_system_type,
    total_gb          = CAST(vs.total_bytes     / 1073741824.0 AS DECIMAL(18,2)),
    livre_gb          = CAST(vs.available_bytes / 1073741824.0 AS DECIMAL(18,2)),
    livre_pct         = CAST(100.0 * vs.available_bytes / NULLIF(vs.total_bytes,0) AS DECIMAL(5,2)),
    alerta            = CASE
                            WHEN 100.0 * vs.available_bytes / NULLIF(vs.total_bytes,0) < 5  THEN 'CRITICO'
                            WHEN 100.0 * vs.available_bytes / NULLIF(vs.total_bytes,0) < 15 THEN 'ATENCAO'
                            ELSE 'ok' END
FROM sys.master_files AS mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
ORDER BY livre_pct ASC;


/* ---------------------------------------------------------------------------
   BLOCO 2 - Tamanho e espaco livre INTERNO de cada arquivo
   Espaco livre interno e diferente de espaco livre no disco: e o quanto o
   arquivo ja reservou e ainda nao usou.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('tempdb..#ArquivosDeBanco') IS NOT NULL
    DROP TABLE #ArquivosDeBanco;

CREATE TABLE #ArquivosDeBanco
(
    banco            sysname,
    arquivo_logico   sysname,
    tipo             NVARCHAR(60),
    arquivo_fisico   NVARCHAR(400),
    tamanho_mb       DECIMAL(18,2),
    usado_mb         DECIMAL(18,2),
    livre_interno_mb DECIMAL(18,2),
    crescimento      NVARCHAR(40),
    tamanho_maximo   NVARCHAR(40)
);

EXEC sp_MSforeachdb N'
USE [?];
INSERT INTO #ArquivosDeBanco
SELECT
    DB_NAME(),
    f.name,
    f.type_desc,
    f.physical_name,
    CAST(f.size * 8.0 / 1024 AS DECIMAL(18,2)),
    CAST(FILEPROPERTY(f.name, ''SpaceUsed'') * 8.0 / 1024 AS DECIMAL(18,2)),
    CAST((f.size - FILEPROPERTY(f.name, ''SpaceUsed'')) * 8.0 / 1024 AS DECIMAL(18,2)),
    CASE WHEN f.is_percent_growth = 1
         THEN CAST(f.growth AS VARCHAR(10)) + '' %''
         ELSE CAST(CAST(f.growth * 8.0 / 1024 AS DECIMAL(18,2)) AS VARCHAR(20)) + '' MB'' END,
    CASE WHEN f.max_size = -1        THEN ''ILIMITADO''
         WHEN f.max_size = 268435456 THEN ''ILIMITADO (log)''
         ELSE CAST(CAST(f.max_size * 8.0 / 1024 AS DECIMAL(18,2)) AS VARCHAR(20)) + '' MB'' END
FROM sys.database_files AS f;';

SELECT
    a.banco,
    a.arquivo_logico,
    a.tipo,
    a.tamanho_mb,
    a.usado_mb,
    a.livre_interno_mb,
    livre_interno_pct = CAST(100.0 * a.livre_interno_mb / NULLIF(a.tamanho_mb,0) AS DECIMAL(5,2)),
    a.crescimento,
    a.tamanho_maximo,
    a.arquivo_fisico,
    alerta = CASE
        WHEN a.crescimento LIKE '%!%%' ESCAPE '!'
            THEN 'crescimento percentual - trocar para MB fixo'
        WHEN 100.0 * a.livre_interno_mb / NULLIF(a.tamanho_mb,0) < 10
            THEN 'pouco espaco interno - autogrow iminente'
        ELSE 'ok' END
FROM #ArquivosDeBanco AS a
ORDER BY a.tamanho_mb DESC;

DROP TABLE #ArquivosDeBanco;


/* ---------------------------------------------------------------------------
   BLOCO 3 - Latencia REAL de I/O por arquivo, desde o restart
   Este bloco encerra a discussao "o disco esta lento" com numero.
   --------------------------------------------------------------------------- */
SELECT
    banco               = DB_NAME(vfs.database_id),
    arquivo_logico      = mf.name,
    tipo                = mf.type_desc,
    leituras            = vfs.num_of_reads,
    escritas            = vfs.num_of_writes,
    latencia_leitura_ms = CASE WHEN vfs.num_of_reads = 0 THEN 0
                               ELSE vfs.io_stall_read_ms  * 1.0 / vfs.num_of_reads END,
    latencia_escrita_ms = CASE WHEN vfs.num_of_writes = 0 THEN 0
                               ELSE vfs.io_stall_write_ms * 1.0 / vfs.num_of_writes END,
    lido_gb             = vfs.num_of_bytes_read    / 1073741824.0,
    escrito_gb          = vfs.num_of_bytes_written / 1073741824.0,
    arquivo_fisico      = mf.physical_name,
    avaliacao = CASE
        WHEN mf.type_desc = 'LOG'
             AND (CASE WHEN vfs.num_of_writes = 0 THEN 0
                       ELSE vfs.io_stall_write_ms * 1.0 / vfs.num_of_writes END) > 5
            THEN 'LOG com latencia de escrita alta - impacta WRITELOG'
        WHEN mf.type_desc = 'ROWS'
             AND (CASE WHEN vfs.num_of_reads = 0 THEN 0
                       ELSE vfs.io_stall_read_ms * 1.0 / vfs.num_of_reads END) > 20
            THEN 'DADOS com latencia de leitura alta - verificar plano antes do disco'
        ELSE 'dentro do esperado' END
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
INNER JOIN sys.master_files AS mf
        ON mf.database_id = vfs.database_id
       AND mf.file_id     = vfs.file_id
ORDER BY (vfs.io_stall_read_ms + vfs.io_stall_write_ms) DESC;

/* ===========================================================================
   COMO LER O RESULTADO

   BLOCO 1 com alerta CRITICO
       Emergencia de disco. Antes de encolher qualquer arquivo, verifique
       backups antigos, arquivos .trn acumulados e o proprio tempdb.

   BLOCO 2 com crescimento percentual
       Cada autogrow fica maior que o anterior. Troque para MB fixo. Em
       arquivos de LOG isso e especialmente ruim: gera muitos VLFs.

   BLOCO 3 com latencia alta em arquivo de DADOS
       Antes de culpar o storage, confirme que nao e uma query varrendo tabela
       inteira por falta de indice. Na pratica, a maioria dos "problemas de
       disco" no SQL Server sao problemas de plano de execucao.
       Va para ../performance/queries-que-mais-fazem-io.sql

   BLOCO 3 com latencia alta em arquivo de LOG
       Aqui sim costuma ser storage. O log e gravado de forma sequencial e
       sincrona: latencia alta de escrita aparece direto como WRITELOG e
       afeta TODA transacao que faz commit.

   OBSERVACAO SOBRE AS MEDIAS
       As latencias sao medias desde o restart da instancia. Um pico de
       madrugada fica diluido. Para medir uma janela especifica, colete o
       BLOCO 3 duas vezes e calcule a diferenca.
   =========================================================================== */
