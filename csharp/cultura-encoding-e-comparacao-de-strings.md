# Cultura, encoding e comparação de strings

> Valor que virou mil vezes maior, acento que virou `Jos�`, busca que não encontra o registro que
> existe. Três defeitos diferentes, três causas específicas.

| | |
|---|---|
| **Compatibilidade** | .NET Framework 4.5+ e .NET Core/5+. `CodePagesEncodingProvider` é necessário apenas em .NET Core/5+. |
| **Impacto** | Nenhum, exceto onde indicado (mudança de collation em coluna). |

---

## Parte 1 — Cultura em números e datas

### O problema

```csharp
decimal.Parse("1.234")   // pt-BR: 1234        en-US: 1,234
decimal.Parse("1,50")    // pt-BR: 1,5         en-US: 150
```

O mesmo texto, dois valores. Um arquivo de integração processado corretamente por dois anos passa a
gerar valores mil vezes maiores porque a aplicação foi para um servidor com outra cultura, ou para
um contêiner Linux onde a cultura padrão é a invariante.

**Ninguém percebe imediatamente**, porque `1.234` é um número válido nas duas leituras. Não há
exceção — há dado errado.

### A regra

> **Cultura invariante para máquina; cultura do usuário para tela.**

| Destino | Cultura |
|---|---|
| Arquivo de integração, JSON, XML, log, chave de cache, URL | `CultureInfo.InvariantCulture` |
| Tela, relatório impresso, e-mail ao cliente | `CultureInfo.CurrentCulture` (ou a cultura escolhida) |

```csharp
// Leitura de integracao: SEMPRE explicita
if (!decimal.TryParse(campo,
                      NumberStyles.Number,
                      CultureInfo.InvariantCulture,
                      out var valor))
{
    throw new FormatException($"Valor invalido na linha {numeroLinha}: '{campo}'.");
}

// Escrita de integracao
var texto = valor.ToString(CultureInfo.InvariantCulture);

// Apresentacao ao usuario brasileiro
var exibicao = valor.ToString("N2", new CultureInfo("pt-BR"));   // 1.234,50
```

**Prefira `TryParse` a `Parse`** em qualquer entrada externa. `Parse` lança exceção; em um arquivo
de 200 mil linhas, isso significa perder o contexto de qual linha falhou, a menos que se envolva
cada chamada em `try/catch` — o que é caro e verboso.

### Quando o arquivo vem em `pt-BR`

Contrato de integração brasileiro frequentemente usa vírgula decimal e `dd/MM/yyyy`. Isso é
legítimo — desde que seja **explícito**:

```csharp
// Uma unica instancia, reutilizada. Nao dependa da cultura do servidor.
private static readonly CultureInfo CulturaDoArquivo = new("pt-BR");

decimal.TryParse(campo, NumberStyles.Number, CulturaDoArquivo, out var valor);

DateTime.TryParseExact(campoData, "dd/MM/yyyy",
                       CulturaDoArquivo, DateTimeStyles.None, out var data);
```

`TryParseExact` com formato declarado é melhor que `TryParse` para arquivo: ele rejeita o que não
corresponde exatamente ao contrato, em vez de adivinhar.

### Cultura da thread

```csharp
// Definir na inicializacao torna o comportamento previsivel,
// independentemente da configuracao do servidor.
CultureInfo.DefaultThreadCurrentCulture   = new CultureInfo("pt-BR");
CultureInfo.DefaultThreadCurrentUICulture = new CultureInfo("pt-BR");
```

Isso resolve a apresentação — e **não dispensa** a cultura explícita nas integrações. Depender da
cultura ambiente é exatamente o que produz o defeito.

> **Modo *globalization invariant*.** Contêineres .NET podem ser publicados com
> `InvariantGlobalization=true`, o que reduz o tamanho da imagem e **desativa** as culturas: toda
> `CultureInfo` se comporta como invariante e `new CultureInfo("pt-BR")` pode falhar. Se a
> formatação mudou depois de conteinerizar, verifique essa propriedade no `.csproj` antes de
> procurar em outro lugar.

---

## Parte 2 — Comparação de strings

### O problema

```csharp
"STRASSE".Equals("STRAsSE", StringComparison.CurrentCultureIgnoreCase)
// O resultado depende da cultura corrente. Regras linguisticas nao sao intuitivas.

// O caso mais conhecido: a cultura turca trata 'I' e 'i' como letras distintas.
// "FILE".ToLower() em tr-TR produz "fıle", com i sem ponto.
if (nomeArquivo.ToLower().EndsWith(".pdf")) { }   // falha em tr-TR
```

O chamado *Turkish-I problem* é o exemplo clássico, mas o problema é geral: **comparação sensível
à cultura aplicada a identificadores** produz resultado que varia com a configuração da máquina.

### A regra

| O que está sendo comparado | `StringComparison` |
|---|---|
| Identificador, chave, código, caminho de arquivo, nome de cabeçalho HTTP | `Ordinal` |
| Idem, ignorando caixa | `OrdinalIgnoreCase` |
| Texto exibido ao usuário, para **ordenação** | `CurrentCulture` |
| Comparação linguística independente de máquina | `InvariantCulture` |

```csharp
// Certo para identificador
if (string.Equals(codigo, "PEDIDO", StringComparison.OrdinalIgnoreCase)) { }
if (caminho.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase)) { }

// Certo para ordenar uma lista que sera exibida
var ordenados = clientes.OrderBy(c => c.Nome, StringComparer.CurrentCulture);

// Dicionario com chave textual: declare o comparador
var porCodigo = new Dictionary<string, Produto>(StringComparer.OrdinalIgnoreCase);
```

`Ordinal` compara byte a byte. É o mais rápido, o mais previsível e o correto na grande maioria dos
casos dentro de um sistema — porque quase tudo que se compara em código é identificador, não texto
em linguagem natural.

> **Nunca use `ToLower()` ou `ToUpper()` para comparar.** Além do problema de cultura, isso aloca
> uma string nova a cada comparação. `StringComparison.OrdinalIgnoreCase` faz o mesmo trabalho sem
> alocar.

### Comparação com acento

Para busca que deve ignorar acento ("jose" encontrando "José"), o .NET não oferece uma opção
direta em `StringComparison`. Duas abordagens:

```csharp
// Normalizacao: decompoe e remove os sinais diacriticos
public static string RemoverAcentos(string texto)
{
    var decomposto = texto.Normalize(NormalizationForm.FormD);
    var construtor = new StringBuilder(decomposto.Length);

    foreach (var caractere in decomposto)
    {
        if (CharUnicodeInfo.GetUnicodeCategory(caractere)
            != UnicodeCategory.NonSpacingMark)
        {
            construtor.Append(caractere);
        }
    }

    return construtor.ToString().Normalize(NormalizationForm.FormC);
}
```

Na maior parte dos casos, porém, a resposta certa é **deixar o SQL Server fazer isso**, com uma
collation *accent insensitive* — ver a próxima seção. Trazer todas as linhas para memória e
normalizar em C# não escala.

---

## Parte 3 — Collation no SQL Server

A collation determina, no banco, como texto é comparado e ordenado. O padrão em instalações
brasileiras costuma ser `SQL_Latin1_General_CP1_CI_AS`:

- `CI` = *case insensitive* — `'ABC' = 'abc'`
- `AS` = *accent sensitive* — `'José' <> 'Jose'`

```sql
-- Collation do banco atual
SELECT DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS collation_do_banco;

-- Collation por coluna: revela divergencias
SELECT c.name AS coluna, t.name AS tipo, c.collation_name
  FROM sys.columns AS c
  JOIN sys.types   AS t ON t.user_type_id = c.user_type_id
 WHERE c.object_id = OBJECT_ID('dbo.Cliente')
   AND c.collation_name IS NOT NULL;
```

### Busca ignorando acento, no banco

```sql
-- Encontra 'Jose', 'José' e 'JOSÉ'
SELECT Id, Nome
  FROM dbo.Cliente
 WHERE Nome COLLATE Latin1_General_CI_AI LIKE 'jose%';
```

> **Cuidado de performance:** aplicar `COLLATE` sobre a coluna a torna não SARGable — o índice
> deixa de ser usado e a consulta vira scan. Em tabela grande, a solução é uma coluna persistida
> com a collation desejada e índice próprio, ou Full-Text Search. Ver
> [`sql-server/performance/`](../sql-server/performance/).

### Erro de collation conflitante

```text
Cannot resolve the collation conflict between "X" and "Y" in the equal to operation.
```

Aparece ao juntar colunas de bancos com collations diferentes — tipicamente após um restore de
outro servidor. A solução pontual é explicitar a collation no `JOIN`:

```sql
SELECT a.Id, b.Descricao
  FROM BancoA.dbo.Item     AS a
  JOIN BancoB.dbo.Catalogo AS b
    ON a.Codigo COLLATE DATABASE_DEFAULT = b.Codigo COLLATE DATABASE_DEFAULT;
```

Isso resolve o erro e **degrada o plano** pelo mesmo motivo acima. A correção de verdade é
uniformizar a collation — operação de esquema, com janela, não algo para as três da manhã.

### `VARCHAR` versus `NVARCHAR`

Em C#, `string` é sempre Unicode. Ao passar um parâmetro sem declarar o tipo, o driver gera
`NVARCHAR`. Se a coluna for `VARCHAR`, o SQL Server aplica `CONVERT_IMPLICIT` **na coluna** — e o
índice deixa de ser usado.

```csharp
// Gera NVARCHAR: pode invalidar o seek em coluna VARCHAR
comando.Parameters.AddWithValue("@Documento", documento);

// Gera VARCHAR: correto
comando.Parameters.Add("@Documento", SqlDbType.VarChar, 14).Value = documento;
```

Esse é um dos diagnósticos mais frequentes de "a query é simples e está lenta". Ver
[`acesso-a-dados/ado-net/`](../acesso-a-dados/ado-net/) e
[`seguranca/sql-injection/`](../seguranca/sql-injection/prevenir-e-encontrar-sql-injection.md).

---

## Parte 4 — Encoding de arquivos

### O sintoma

`José` aparece como `JosÃ©` (UTF-8 lido como Latin-1) ou como `Jos�` (Latin-1 lido como UTF-8).

### A regra

> **Encoding não é detectável com segurança. Ele faz parte do contrato de integração.**

```csharp
// Leitura com encoding explicito
using var leitor = new StreamReader(caminho, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);

// Escrita em UTF-8 SEM BOM — o que a maioria dos parceiros espera
var utf8SemBom = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);
using var escritor = new StreamWriter(caminho, append: false, utf8SemBom);
```

O **BOM** (`EF BB BF` no início do arquivo) é causa recorrente de rejeição: o parceiro lê os três
bytes como parte do primeiro campo. `new UTF8Encoding(false)` resolve; `Encoding.UTF8` (a
propriedade estática) emite BOM ao escrever.

### Arquivo legado em Windows-1252 ou ISO-8859-1

No .NET Framework, essas páginas de código estão disponíveis. No .NET Core/5+, **não estão** — é
preciso registrar o provedor:

```csharp
// Uma vez, na inicializacao da aplicacao.
// Pacote: System.Text.Encoding.CodePages
Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

// So depois disso:
var latin1 = Encoding.GetEncoding("ISO-8859-1");
var win1252 = Encoding.GetEncoding(1252);
```

Sem o registro, `Encoding.GetEncoding(1252)` lança `NotSupportedException` — exceção que costuma
aparecer pela primeira vez em produção, na primeira integração legada do dia.

### `BULK INSERT` e `bcp` no SQL Server

```sql
-- CODEPAGE = '65001' significa UTF-8.
-- Suporte a UTF-8 em BULK INSERT existe a partir do SQL Server 2016 (13.x).
BULK INSERT dbo.Staging
FROM 'C:\integracao\arquivo.csv'
WITH (
    FORMAT      = 'CSV',
    CODEPAGE    = '65001',
    FIRSTROW    = 2,
    FIELDTERMINATOR = ';',
    ROWTERMINATOR   = '0x0a'
);
```

`ROWTERMINATOR = '0x0a'` trata arquivo com quebra de linha estilo Unix. Arquivo do Windows usa
`'\r\n'`. Misturar os dois deixa um `\r` invisível no fim de cada último campo — e a comparação
com o valor esperado falha sem motivo aparente.

Mais sobre integração por arquivo em
[`api-integracao/arquivos/`](../api-integracao/arquivos/).

---

## Checklist

- [ ] Toda conversão de número ou data em integração declara a cultura explicitamente.
- [ ] `TryParse`/`TryParseExact` em entrada externa, nunca `Parse`.
- [ ] Nenhum código depende da cultura ambiente do servidor para produzir dado.
- [ ] `InvariantGlobalization` verificado antes de investigar formatação em contêiner.
- [ ] `StringComparison.Ordinal`/`OrdinalIgnoreCase` para identificadores.
- [ ] Nenhum `ToLower()`/`ToUpper()` usado para comparar.
- [ ] `Dictionary`/`HashSet` com chave textual declaram o `StringComparer`.
- [ ] Parâmetro SQL com tipo declarado, evitando `CONVERT_IMPLICIT` de `NVARCHAR` em `VARCHAR`.
- [ ] Encoding de cada arquivo de integração **documentado no contrato**, não detectado.
- [ ] UTF-8 sem BOM na escrita, salvo exigência contrária do parceiro.
- [ ] `CodePagesEncodingProvider` registrado quando há arquivo legado em .NET Core/5+.

---

## Referências

- [Microsoft Learn — Best practices for comparing strings in .NET](https://learn.microsoft.com/dotnet/standard/base-types/best-practices-strings)
- [Microsoft Learn — `CultureInfo`](https://learn.microsoft.com/dotnet/api/system.globalization.cultureinfo)
- [Microsoft Learn — Globalization Invariant Mode](https://learn.microsoft.com/dotnet/core/runtime-config/globalization)
- [Microsoft Learn — `CodePagesEncodingProvider`](https://learn.microsoft.com/dotnet/api/system.text.codepagesencodingprovider)
- [Microsoft Learn — Collation e suporte a Unicode no SQL Server](https://learn.microsoft.com/sql/relational-databases/collations/collation-and-unicode-support)

---

**Criado por Fábio Cerqueira**
