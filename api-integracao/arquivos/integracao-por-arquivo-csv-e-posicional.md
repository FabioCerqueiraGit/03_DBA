# Integração por arquivo — CSV, posicional e SFTP

> Integração por arquivo parece a mais simples e é a que mais causa incidente de dado:
> arquivo lido pela metade, arquivo processado duas vezes, separador dentro do campo,
> acento corrompido. Nenhum desses problemas aparece no teste com três linhas.

| | |
|---|---|
| **Compatibilidade** | .NET Framework 4.6.2+ · .NET 8 · .NET 10 |
| **Pacotes** | `CsvHelper` · `SSH.NET` (SFTP) · `Microsoft.Data.SqlClient` |
| **Impacto** | Reprocessamento duplica dado; leitura parcial grava dado incompleto |

---

## Os quatro problemas clássicos

| # | Problema | Consequência |
|---|---|---|
| 1 | Ler o arquivo **enquanto ele ainda está sendo escrito** | Metade dos registros processados; o resto perdido |
| 2 | Processar o **mesmo arquivo duas vezes** | Lançamento duplicado |
| 3 | `Split(',')` em CSV | Qualquer campo com vírgula quebra o layout |
| 4 | Encoding e cultura | Acento corrompido; `1.234,56` virando `1.234` |

Os dois primeiros são de **protocolo**; os dois últimos, de **parsing**. Trate os dois
primeiros antes de escrever a primeira linha de leitura.

---

## Problema 1 — Arquivo incompleto

O parceiro grava um arquivo de 80 MB por FTP. Seu job roda de minuto em minuto, encontra o
arquivo com 12 MB e começa a processar.

### Solução A — Arquivo de controle (a mais usada)

O produtor grava `pedidos_20260820.csv` e, **só depois de terminar**, grava um arquivo
vazio `pedidos_20260820.ok`. O consumidor só olha para os `.ok`.

```csharp
foreach (var controle in Directory.EnumerateFiles(pastaEntrada, "*.ok"))
{
    var dados = Path.ChangeExtension(controle, ".csv");

    if (!File.Exists(dados))
    {
        _logger.LogWarning("Controle {Controle} sem arquivo de dados", controle);
        continue;
    }

    await ProcessarAsync(dados, cancellationToken);

    File.Delete(controle);
}
```

### Solução B — Gravação temporária e rename atômico

O produtor grava como `.tmp` e **renomeia** ao terminar. Rename dentro do mesmo volume é
atômico: o arquivo com o nome final nunca está incompleto.

```csharp
// Do lado do PRODUTOR
var temporario = destino + ".tmp";

await using (var saida = File.Create(temporario))
{
    await GravarAsync(saida, cancellationToken);
    await saida.FlushAsync(cancellationToken);
}

File.Move(temporario, destino);   // atomico no mesmo volume
```

### Solução C — Verificar que o arquivo não está em uso

Quando você não controla o produtor:

```csharp
private static bool EstaLiberado(string caminho)
{
    try
    {
        // Abrir sem compartilhamento falha se alguem ainda esta escrevendo.
        using var _ = File.Open(caminho, FileMode.Open, FileAccess.Read, FileShare.None);
        return true;
    }
    catch (IOException)
    {
        return false;
    }
}
```

Menos confiável que A e B — há clientes de FTP que fecham e reabrem o arquivo — mas melhor
que nada. Combine com uma checagem de tamanho estável entre duas leituras.

> **`FileSystemWatcher` não resolve o problema 1.** Ele dispara na **criação**, não na
> conclusão da escrita. Ele também perde eventos sob rajada e não funciona de forma
> confiável em alguns compartilhamentos de rede. Para integração, prefira varredura
> periódica com arquivo de controle.

---

## Problema 2 — Reprocessamento

O job caiu no meio, subiu de novo e reprocessou o arquivo inteiro. Ou alguém copiou o
arquivo de volta para a pasta "por segurança".

### Registrar o que já foi processado

```sql
CREATE TABLE dbo.ArquivoProcessado
(
    NomeDoArquivo   VARCHAR(260)  NOT NULL,
    HashDoConteudo  BINARY(32)    NOT NULL,   -- SHA-256
    TamanhoBytes    BIGINT        NOT NULL,
    LinhasLidas     INT           NOT NULL,
    ProcessadoEm    DATETIME2(3)  NOT NULL
                    CONSTRAINT DF_ArquivoProcessado_ProcessadoEm DEFAULT SYSUTCDATETIME(),

    CONSTRAINT PK_ArquivoProcessado PRIMARY KEY CLUSTERED (NomeDoArquivo)
);
GO

/* O hash pega o caso do arquivo reenviado com outro nome */
CREATE UNIQUE NONCLUSTERED INDEX UX_ArquivoProcessado_Hash
    ON dbo.ArquivoProcessado (HashDoConteudo);
GO
```

```csharp
public static async Task<byte[]> CalcularHashAsync(string caminho, CancellationToken ct)
{
    await using var stream = File.OpenRead(caminho);
    using var sha = SHA256.Create();
    return await sha.ComputeHashAsync(stream, ct).ConfigureAwait(false);
}
```

> `SHA256.ComputeHashAsync` existe a partir do .NET 5. Em .NET Framework, use
> `sha.ComputeHash(stream)` de forma síncrona.

O **hash** cobre o caso que o nome não cobre: o mesmo conteúdo reenviado como
`pedidos_20260820_v2.csv`. A constraint `UNIQUE` é quem garante isso de verdade, sem
janela de concorrência — mesmo princípio de
[`../resiliencia/retry-seguro-e-idempotencia.md`](../resiliencia/retry-seguro-e-idempotencia.md).

### Mover o arquivo ao terminar

```text
entrada/          <- o produtor grava aqui
processando/      <- movido no inicio (protege de dois jobs simultaneos)
processado/2026/08/20/
quarentena/       <- falhou; alguem precisa olhar
```

Mover para `processando/` **antes** de começar resolve dois problemas de uma vez: evita que
uma segunda instância do job pegue o mesmo arquivo, e deixa visível o que ficou preso
quando o processo morre no meio.

---

## Problema 3 — CSV não se lê com `Split`

```csharp
// ❌ Quebra em qualquer campo com virgula, aspas ou quebra de linha
var campos = linha.Split(',');
```

```text
48213,"SILVA, JOAO",1234.56
```

O `Split(',')` devolve quatro campos onde existem três. E CSV **permite quebra de linha
dentro de campo entre aspas** — o que significa que nem ler linha a linha é seguro.

### Use uma biblioteca

```csharp
using CsvHelper;
using CsvHelper.Configuration;

var configuracao = new CsvConfiguration(CultureInfo.InvariantCulture)
{
    Delimiter        = ";",       // padrao brasileiro; confirme com o parceiro
    HasHeaderRecord  = true,
    TrimOptions      = TrimOptions.Trim,
    MissingFieldFound = null,     // campo ausente nao lanca
    BadDataFound     = contexto =>
        _logger.LogWarning("Linha {Linha} com dado malformado", contexto.RawRecord)
};

await using var stream = File.OpenRead(caminho);
using var leitor = new StreamReader(stream, Encoding.UTF8);
using var csv = new CsvReader(leitor, configuracao);

await foreach (var registro in csv.GetRecordsAsync<PedidoCsv>(cancellationToken))
{
    // GetRecordsAsync faz streaming: memoria constante
    await ProcessarAsync(registro, cancellationToken);
}
```

```csharp
public sealed class PedidoCsv
{
    [Name("numero_pedido")]  public int Numero { get; set; }
    [Name("cliente")]        public string Cliente { get; set; } = "";
    [Name("valor_total")]    public decimal ValorTotal { get; set; }
    [Name("data_emissao")]
    [Format("yyyy-MM-dd")]   public DateTime Emissao { get; set; }
}
```

### O separador brasileiro

Em pt-BR, o Excel usa **ponto e vírgula** como separador de CSV, porque a vírgula é o
separador decimal. Um arquivo gerado "exportando do Excel" quase sempre vem com `;` e com
números no formato `1.234,56`.

```csharp
// Quando o parceiro manda numero em formato brasileiro
var configuracao = new CsvConfiguration(new CultureInfo("pt-BR"))
{
    Delimiter = ";"
};
```

**Fixe isso no contrato da integração**, por escrito: separador, formato de número, formato
de data e encoding. Descobrir isso por tentativa e erro a cada arquivo novo é a rotina de
quem não documentou.

---

## Problema 4 — Encoding

```csharp
// ❌ Assume UTF-8. Arquivo em ISO-8859-1 vira "Conceição"
using var leitor = new StreamReader(caminho);

// ✅ Encoding explicito, combinado com o parceiro
using var leitor = new StreamReader(caminho, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);

// ✅ Sistema legado brasileiro: quase sempre ISO-8859-1 ou Windows-1252
Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);   // .NET Core+
using var leitor = new StreamReader(caminho, Encoding.GetEncoding("ISO-8859-1"));
```

Um teste rápido para descobrir o encoding de um arquivo desconhecido: procure uma palavra
que você sabe que tem acento. Se aparecer como `Ã§` ou `Ã£`, o arquivo é UTF-8 lido como
latin; se aparecer como `?` ou losango, é o contrário.

---

## Layout posicional (largura fixa)

Comum em bancos, CNAB e sistemas de folha. Cada campo ocupa uma faixa de colunas.

```text
0148213SILVA JOAO                    00000123456202608200001
^ ^     ^                            ^          ^       ^
| |     |                            |          |       sequencial
| |     |                            |          data (AAAAMMDD)
| |     |                            valor em centavos, sem separador
| |     nome (30 posicoes)
| numero do pedido (6 posicoes)
tipo de registro (2 posicoes)
```

```csharp
public static PedidoPosicional Interpretar(string linha)
{
    // Valide o tamanho ANTES de fatiar: linha truncada gera
    // ArgumentOutOfRangeException no meio do lote.
    const int TamanhoEsperado = 60;

    if (linha.Length != TamanhoEsperado)
    {
        throw new FormatException(
            $"Linha com {linha.Length} posicoes; esperado {TamanhoEsperado}.");
    }

    return new PedidoPosicional
    {
        TipoDeRegistro = linha.Substring(0, 2),
        Numero         = int.Parse(linha.Substring(2, 6), CultureInfo.InvariantCulture),
        Nome           = linha.Substring(8, 30).TrimEnd(),

        // Valor em centavos: divida, nunca insira ponto por string
        ValorTotal     = decimal.Parse(linha.Substring(38, 11), CultureInfo.InvariantCulture) / 100m,

        Emissao        = DateTime.ParseExact(linha.Substring(49, 8), "yyyyMMdd",
                                             CultureInfo.InvariantCulture)
    };
}
```

Três cuidados que evitam a maior parte dos incidentes:

- **valide o tamanho da linha** antes de fatiar;
- **valor em centavos se divide por 100**, com `decimal` — nunca monte a string com ponto;
- **espaços à direita** são preenchimento, não dado: `TrimEnd()`. Mas cuidado com campos em
  que o espaço à esquerda é significativo (números preenchidos com zero à esquerda).

Layouts posicionais costumam ter **registro de cabeçalho, detalhe e rodapé**, com o rodapé
trazendo a contagem e a soma. **Confira esses totais** — é a validação mais barata contra
arquivo truncado que existe.

---

## Carregar no banco

Para volume, `SqlBulkCopy` é a diferença entre minutos e horas:

```csharp
await using var conexao = new SqlConnection(_connectionString);
await conexao.OpenAsync(cancellationToken);

await using var transacao = (SqlTransaction)await conexao
    .BeginTransactionAsync(cancellationToken);

try
{
    using (var bulk = new SqlBulkCopy(conexao, SqlBulkCopyOptions.Default, transacao)
    {
        DestinationTableName = "dbo.PedidoStaging",
        BatchSize            = 5000,
        BulkCopyTimeout      = 300,
        EnableStreaming      = true
    })
    {
        bulk.ColumnMappings.Add(nameof(PedidoCsv.Numero),     "Numero");
        bulk.ColumnMappings.Add(nameof(PedidoCsv.Cliente),    "Cliente");
        bulk.ColumnMappings.Add(nameof(PedidoCsv.ValorTotal), "ValorTotal");
        bulk.ColumnMappings.Add(nameof(PedidoCsv.Emissao),    "Emissao");

        await bulk.WriteToServerAsync(leitorDeDados, cancellationToken);
    }

    // MERGE da staging para a tabela final, dentro da MESMA transacao
    await ConsolidarAsync(conexao, transacao, cancellationToken);

    await RegistrarArquivoProcessadoAsync(conexao, transacao, arquivo, cancellationToken);

    await transacao.CommitAsync(cancellationToken);
}
catch
{
    await transacao.RollbackAsync(CancellationToken.None);
    throw;
}
```

**O padrão staging → consolidação → registro do arquivo, tudo na mesma transação**, é o que
torna a carga *tudo ou nada*. Sem ele, uma falha no meio deixa metade do arquivo aplicada
e o arquivo não marcado — e o reprocessamento duplica a primeira metade.

Sempre declare `ColumnMappings`: sem eles o mapeamento é posicional, e uma coluna nova na
tabela quebra a carga em silêncio.

> Carga muito grande em uma única transação gera transaction log enorme. Para arquivos de
> milhões de linhas, processe em lotes com `COMMIT` por lote e controle de ponto de
> retomada. Veja
> [`../../sql-server/troubleshooting/por-que-o-transaction-log-esta-crescendo.md`](../../sql-server/troubleshooting/por-que-o-transaction-log-esta-crescendo.md).

---

## SFTP

```csharp
using Renci.SshNet;

var metodo = new PrivateKeyAuthenticationMethod(
    "<USUARIO>",
    new PrivateKeyFile("<CAMINHO-DA-CHAVE>", "<SENHA-DA-CHAVE>"));

var conexao = new ConnectionInfo("<HOST>", 22, "<USUARIO>", metodo);

using var cliente = new SftpClient(conexao);
cliente.Connect();

foreach (var arquivo in cliente.ListDirectory("/entrada"))
{
    if (arquivo.IsDirectory || !arquivo.Name.EndsWith(".ok", StringComparison.OrdinalIgnoreCase))
        continue;

    var nomeDados = Path.ChangeExtension(arquivo.Name, ".csv");
    var destino   = Path.Combine(pastaLocal, nomeDados);

    await using (var local = File.Create(destino))
    {
        cliente.DownloadFile($"/entrada/{nomeDados}", local);
    }

    // So remove da origem DEPOIS de gravar localmente com sucesso
    cliente.DeleteFile($"/entrada/{nomeDados}");
    cliente.DeleteFile($"/entrada/{arquivo.Name}");
}
```

**SFTP e FTPS não são a mesma coisa.** SFTP roda sobre SSH (porta 22); FTPS é FTP com TLS
(portas 21/990). Confundir os dois é a causa mais comum de "não conecta" no primeiro dia
de uma integração.

**FTP simples não deve ser usado**: credencial e conteúdo trafegam em texto claro.

Guarde a chave privada fora do repositório e valide o *host key* do servidor — aceitar
qualquer host key anula a proteção contra ataque de intermediário.

---

## Quando algo dá errado

| Situação | O que fazer |
|---|---|
| Linha malformada isolada | Registrar, pular, **continuar**. Rejeitar o arquivo inteiro por uma linha costuma ser pior |
| Muitas linhas rejeitadas (acima de um limite) | Abortar e mandar o arquivo para `quarentena/` |
| Totais do rodapé não batem | **Abortar.** O arquivo está truncado |
| Arquivo já processado (hash ou nome) | Ignorar e registrar em `Information` — não é erro |
| Falha no meio da carga | Rollback completo; arquivo permanece não processado |

Defina o **limite de rejeição** por escrito: "acima de 5% das linhas, o arquivo vai para
quarentena". Sem esse número, cada incidente vira uma decisão improvisada.

---

## Reconciliação

Toda integração por arquivo precisa de uma conferência periódica:

```text
Diariamente:
  1. arquivos esperados x arquivos recebidos  -> faltou algum?
  2. linhas recebidas x linhas processadas    -> perdeu alguma?
  3. totais do rodape x totais gravados       -> bate?
  4. registrar o resultado, mesmo quando esta tudo certo
```

O passo 4 importa: um relatório dizendo "zero divergências" é a prova de que a
reconciliação rodou. Sem ele, não dá para distinguir "está tudo certo" de "o job parou
semana passada".

---

## Checklist

- [ ] Protocolo de conclusão definido: arquivo `.ok`, rename atômico ou verificação de uso.
- [ ] Arquivo movido para `processando/` antes de começar.
- [ ] Registro de arquivos processados, com **hash** e constraint `UNIQUE`.
- [ ] CSV lido com biblioteca, nunca com `Split`.
- [ ] Separador, encoding, formato de número e de data **documentados no contrato**.
- [ ] Layout posicional com validação de tamanho de linha.
- [ ] Totais de rodapé conferidos.
- [ ] Carga em staging e consolidação na **mesma transação** do registro do arquivo.
- [ ] `SqlBulkCopy` com `ColumnMappings` explícitos.
- [ ] Pasta de quarentena e limite de rejeição definidos.
- [ ] SFTP (não FTP), com chave fora do repositório e host key validada.
- [ ] Reconciliação diária, registrando execução mesmo sem divergência.

## Referências

- [`SqlBulkCopy`](https://learn.microsoft.com/pt-br/dotnet/api/microsoft.data.sqlclient.sqlbulkcopy)
- [CsvHelper](https://joshclose.github.io/CsvHelper/)
- [SSH.NET](https://github.com/sshnet/SSH.NET)
- [`FileStream` e I/O de arquivos](https://learn.microsoft.com/pt-br/dotnet/standard/io/)

---

**Criado por Fábio Cerqueira**
