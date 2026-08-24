# Processar XML — namespaces, encoding, XSD e XXE

> "O XML não é processado" tem quase sempre uma de três causas: **namespace ignorado**,
> **encoding declarado diferente do real**, ou **cultura** transformando `1234.56` em
> outra coisa. E existe uma quarta que ninguém menciona: o parser aceitar uma entidade
> externa e ler arquivos do seu servidor.

| | |
|---|---|
| **Compatibilidade** | .NET Framework 4.6.2+ · .NET 8 · .NET 10 |
| **Impacto** | XXE é vulnerabilidade de leitura de arquivo e SSRF |
| **Contexto típico** | NF-e, SEFAZ, prefeituras, bancos, EDI, SOAP |

---

## Escolher a API certa

| API | Use quando | Evite quando |
|---|---|---|
| **`XmlSerializer`** | Há um esquema estável e você quer objetos tipados | O XML é irregular ou muda com frequência |
| **`XDocument`** (LINQ to XML) | Precisa navegar, consultar e transformar | Arquivo muito grande |
| **`XmlReader`** | Arquivo grande: leitura sequencial, sem carregar tudo | Precisa navegar para trás |
| `XmlDocument` (DOM) | Código legado que já usa | Código novo — prefira `XDocument` |

Regra prática de tamanho: até alguns megabytes, `XDocument`. Acima disso, `XmlReader` —
um arquivo de 200 MB carregado em `XDocument` pode consumir várias vezes isso em memória.

---

## Armadilha 1 — Namespace (a campeã)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<nfeProc xmlns="http://www.portalfiscal.inf.br/nfe" versao="4.00">
  <NFe>
    <infNFe Id="NFe3526...">
      <ide><nNF>48213</nNF></ide>
    </infNFe>
  </NFe>
</nfeProc>
```

```csharp
// ❌ Retorna null. Nao lanca excecao -- so devolve nada.
var numero = documento.Root?.Element("NFe")?
                            .Element("infNFe")?
                            .Element("ide")?
                            .Element("nNF")?.Value;

// ✅ O namespace faz parte do nome do elemento
XNamespace ns = "http://www.portalfiscal.inf.br/nfe";

var numero = documento.Root?.Element(ns + "NFe")?
                            .Element(ns + "infNFe")?
                            .Element(ns + "ide")?
                            .Element(ns + "nNF")?.Value;
```

O que torna isso traiçoeiro: **não há erro**. O código devolve `null` e segue, e o problema
aparece lá na frente como campo vazio no banco.

```csharp
// Descobrir o namespace padrao de um documento desconhecido
XNamespace ns = documento.Root?.GetDefaultNamespace() ?? XNamespace.None;
```

**Atributos normalmente não herdam o namespace padrão.** `Attribute("versao")` funciona
sem prefixo; `Element("ide")` não. Essa assimetria confunde muita gente.

---

## Armadilha 2 — Encoding declarado versus encoding real

```xml
<?xml version="1.0" encoding="UTF-8"?>
```

Essa linha é uma **declaração**, não uma garantia. Se o arquivo foi gravado em
`ISO-8859-1`, o parser tenta ler como UTF-8 e falha — ou pior, lê errado e você descobre
quando "Conceição" vira "Conceição".

```text
There is an invalid character in the given encoding. Line 1, position 42.
```

```csharp
// ✅ Deixe o parser decidir a partir da declaracao e da BOM,
//    lendo o STREAM em vez de uma string ja decodificada.
await using var stream = File.OpenRead(caminho);
var documento = await XDocument.LoadAsync(
    stream, LoadOptions.None, cancellationToken);
```

```csharp
// ✅ Quando o parceiro declara UTF-8 mas envia ISO-8859-1 (acontece muito),
//    force o encoding real, ignorando a declaracao.
var encodingReal = Encoding.GetEncoding("ISO-8859-1");

using var leitor = new StreamReader(caminho, encodingReal, detectEncodingFromByteOrderMarks: false);
var documento = XDocument.Load(leitor);
```

> Em .NET Core e superior, `Encoding.GetEncoding("ISO-8859-1")` exige registrar o provedor
> de páginas de código:
>
> ```csharp
> Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
> ```
> (pacote `System.Text.Encoding.CodePages`). No .NET Framework isso não é necessário.

### Nunca faça isto

```csharp
// ❌ A string ja foi decodificada -- possivelmente errado -- antes do parser ver a declaracao
var texto = File.ReadAllText(caminho);
var documento = XDocument.Parse(texto);
```

Carregue sempre a partir do **stream**, e deixe a decodificação com quem sabe ler a
declaração.

---

## Armadilha 3 — Cultura em números e datas

XML é sempre **cultura invariante**: ponto como separador decimal, data em ISO 8601.

```csharp
// ❌ Em pt-BR, "1234.56" nao converte -- ou converte para 123456
var valor = decimal.Parse(elemento.Value);

// ✅
var valor = decimal.Parse(elemento.Value, CultureInfo.InvariantCulture);

// ✅✅ Melhor ainda: a conversao implicita do XElement ja usa cultura invariante
var valor = (decimal)elemento;
var data  = (DateTime)elemento;
var opcional = (decimal?)elemento;   // null se o elemento nao existir
```

A conversão explícita de `XElement` é o caminho mais seguro: ela usa as regras do XML
Schema, não a cultura do servidor. E a versão anulável resolve elemento ausente sem
`if` aninhado.

Na **escrita**, o mesmo cuidado:

```csharp
// ❌ Usa a cultura corrente: gera "1234,56" e quebra o parceiro
novoElemento.Value = valor.ToString();

// ✅
novoElemento.Value = valor.ToString(CultureInfo.InvariantCulture);

// ✅✅ XElement converte corretamente sozinho
var elemento = new XElement("vNF", valor);
```

---

## Armadilha 4 — XXE (XML External Entity)

Esta não é erro de integração: é **vulnerabilidade**.

```xml
<?xml version="1.0"?>
<!DOCTYPE dados [
  <!ENTITY vazamento SYSTEM "file:///C:/inetpub/wwwroot/web.config">
]>
<pedido><observacao>&vazamento;</observacao></pedido>
```

Com processamento de DTD habilitado e um resolvedor ativo, o parser **lê o arquivo** e
devolve o conteúdo dentro do XML processado. Trocando `file://` por `http://`, o mesmo
ataque vira SSRF — o seu servidor passa a fazer requisições para onde o atacante mandar.

```csharp
// ✅ Configuracao segura para XML de origem externa
var configuracao = new XmlReaderSettings
{
    DtdProcessing = DtdProcessing.Prohibit,   // rejeita DTD por completo
    XmlResolver   = null,                     // nao resolve nada externo
    MaxCharactersFromEntities = 1024,
    MaxCharactersInDocument   = 50 * 1024 * 1024,
    CloseInput = true
};

await using var stream = File.OpenRead(caminho);
using var leitor = XmlReader.Create(stream, configuracao);

var documento = XDocument.Load(leitor);
```

> As versões modernas do .NET adotam padrões seguros — no .NET Core e superior o
> processamento de DTD vem desabilitado, e o .NET Framework endureceu os padrões a partir
> da versão 4.5.2. **Ainda assim, defina explicitamente.** Você não controla em qual
> runtime o código vai rodar daqui a cinco anos, e código legado costuma trazer
> `XmlResolver` configurado à mão de outra época.

`MaxCharactersFromEntities` protege também contra a *billion laughs*: um documento pequeno
com entidades recursivas que se expandem até esgotar a memória.

**Em código legado com `XmlDocument`:**

```csharp
var documento = new XmlDocument { XmlResolver = null };
documento.Load(stream);
```

---

## `XmlSerializer` — mapear para objetos

```csharp
[XmlRoot("pedido", Namespace = "http://<NAMESPACE-DO-PARCEIRO>/v1")]
public sealed class PedidoXml
{
    [XmlElement("numero")]
    public int Numero { get; set; }

    [XmlElement("emissao", DataType = "date")]
    public DateTime Emissao { get; set; }

    [XmlElement("valorTotal")]
    public decimal ValorTotal { get; set; }

    [XmlAttribute("versao")]
    public string Versao { get; set; } = "1.0";

    [XmlArray("itens")]
    [XmlArrayItem("item")]
    public List<ItemXml> Itens { get; set; } = new();
}
```

```csharp
// A instancia de XmlSerializer e CARA de criar: ela gera um assembly em memoria.
// Criar uma por chamada e uma causa classica de vazamento de memoria.
private static readonly XmlSerializer Serializador = new(typeof(PedidoXml));

public static PedidoXml Desserializar(Stream stream)
{
    var configuracao = new XmlReaderSettings
    {
        DtdProcessing = DtdProcessing.Prohibit,
        XmlResolver   = null
    };

    using var leitor = XmlReader.Create(stream, configuracao);

    return (PedidoXml?)Serializador.Deserialize(leitor)
           ?? throw new InvalidOperationException("XML vazio ou invalido.");
}
```

> **O `XmlSerializer` estático não é preciosismo.** Os construtores que recebem apenas
> `Type` têm cache interno; os que recebem parâmetros extras (como `XmlRootAttribute`)
> **não têm** — e cada chamada gera um assembly novo que nunca é descarregado. Em uma API
> movimentada, a memória sobe até o processo reciclar. Se precisar dessas sobrecargas,
> mantenha você mesmo um cache das instâncias.

Ao escrever, controle a formatação e o encoding:

```csharp
var configuracaoEscrita = new XmlWriterSettings
{
    Indent = true,
    Encoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),   // sem BOM
    OmitXmlDeclaration = false
};

await using var saida = File.Create(caminho);
using var escritor = XmlWriter.Create(saida, configuracaoEscrita);

Serializador.Serialize(escritor, pedido);
```

O `encoderShouldEmitUTF8Identifier: false` remove a **BOM**. Muitos parceiros — e vários
validadores de órgão público — rejeitam XML com BOM, com mensagens que não explicam nada.

---

## Validar contra XSD

Validar na entrada transforma "deu erro em algum lugar" em "o campo `vNF` da linha 42 está
fora do padrão".

```csharp
public static IReadOnlyList<string> Validar(Stream xml, string caminhoDoXsd, string namespaceAlvo)
{
    var erros = new List<string>();

    var esquemas = new XmlSchemaSet { XmlResolver = null };
    using (var leitorXsd = XmlReader.Create(
               caminhoDoXsd,
               new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null }))
    {
        esquemas.Add(namespaceAlvo, leitorXsd);
    }

    var configuracao = new XmlReaderSettings
    {
        ValidationType  = ValidationType.Schema,
        Schemas         = esquemas,
        DtdProcessing   = DtdProcessing.Prohibit,
        XmlResolver     = null,
        ValidationFlags = XmlSchemaValidationFlags.ReportValidationWarnings
    };

    configuracao.ValidationEventHandler += (_, e) =>
        erros.Add($"[{e.Severity}] Linha {e.Exception?.LineNumber}, " +
                  $"posicao {e.Exception?.LinePosition}: {e.Message}");

    using var leitor = XmlReader.Create(xml, configuracao);
    while (leitor.Read()) { }   // percorre o documento inteiro para coletar todos os erros

    return erros;
}
```

O `while (leitor.Read())` é o que faz a validação percorrer tudo e **acumular** os erros,
em vez de parar no primeiro. Devolver a lista completa ao parceiro economiza dias de
idas e vindas.

---

## Arquivos grandes — `XmlReader` em streaming

```csharp
public static IEnumerable<XElement> LerPedidos(string caminho)
{
    var configuracao = new XmlReaderSettings
    {
        DtdProcessing = DtdProcessing.Prohibit,
        XmlResolver   = null,
        IgnoreWhitespace = true,
        IgnoreComments   = true
    };

    using var leitor = XmlReader.Create(caminho, configuracao);

    leitor.MoveToContent();

    while (leitor.Read())
    {
        if (leitor.NodeType != XmlNodeType.Element || leitor.Name != "pedido")
            continue;

        // Materializa APENAS o no atual, nao o documento inteiro
        if (XNode.ReadFrom(leitor) is XElement elemento)
            yield return elemento;
    }
}
```

```csharp
foreach (var pedido in LerPedidos(caminho))
{
    // Processa e descarta. A memoria fica constante,
    // independente do tamanho do arquivo.
    Processar(pedido);
}
```

Esse padrão processa um arquivo de gigabytes com consumo de memória estável. É a diferença
entre a carga noturna terminar e o processo morrer com `OutOfMemoryException`.

---

## XML no SQL Server

O SQL Server tem tipo `XML` nativo. Vale conhecer os limites antes de decidir onde
processar.

```sql
/* Extrair campos de uma coluna XML */
SELECT
    numero  = Documento.value('(/pedido/numero)[1]', 'INT'),
    emissao = Documento.value('(/pedido/emissao)[1]', 'DATE'),
    valor   = Documento.value('(/pedido/valorTotal)[1]', 'DECIMAL(18,2)')
FROM dbo.PedidoRecebido
WHERE PedidoId = @PedidoId;

/* Com namespace -- mesma armadilha do C# */
WITH XMLNAMESPACES (DEFAULT 'http://www.portalfiscal.inf.br/nfe')
SELECT numero = Documento.value('(/nfeProc/NFe/infNFe/ide/nNF)[1]', 'VARCHAR(20)')
FROM dbo.NotaRecebida;
```

**Cuidados:**

- consultar `.value()` sobre coluna `XML` **sem índice XML** varre e reprocessa o documento
  a cada linha. Em tabela grande isso domina o plano — confirme em
  [`../../sql-server/performance/queries-que-mais-fazem-io.sql`](../../sql-server/performance/queries-que-mais-fazem-io.sql);
- índice XML acelera a leitura e **encarece bastante a escrita** e o espaço. Só vale quando
  há consulta frequente sobre o conteúdo;
- na maioria dos casos o melhor desenho é **extrair na aplicação** e gravar os campos em
  colunas normais, guardando o XML original apenas como comprovante.

---

## Erros e o que significam

| Erro | Causa | Correção |
|---|---|---|
| Retorna `null`, sem exceção | Namespace ignorado | Usar `XNamespace` |
| `There is an invalid character in the given encoding` | Encoding real diferente do declarado | Carregar do stream, ou forçar o encoding correto |
| `Data at the root level is invalid. Line 1, position 1` | BOM inesperada, ou o conteúdo não é XML (costuma ser HTML de erro) | Inspecionar os primeiros bytes |
| `The 'x' start tag on line N does not match the end tag` | XML malformado na origem | Devolver ao parceiro; não "consertar" com `Replace` |
| `Input string was not in a correct format` ao converter número | Cultura | `CultureInfo.InvariantCulture` ou conversão de `XElement` |
| `OutOfMemoryException` ao carregar | Documento grande em `XDocument` | Trocar por `XmlReader` em streaming |
| `InvalidOperationException: There is an error in XML document (N, M)` | Divergência entre o XML e o mapeamento | Ler a `InnerException`: ela traz o erro real |
| Memória crescendo sem parar | `XmlSerializer` criado por chamada com sobrecarga sem cache | Instância estática ou cache próprio |

---

## Checklist

- [ ] `DtdProcessing = Prohibit` e `XmlResolver = null` em todo XML de origem externa.
- [ ] Limites de tamanho definidos (`MaxCharactersInDocument`, `MaxCharactersFromEntities`).
- [ ] Namespace tratado com `XNamespace`.
- [ ] Carregamento a partir de **stream**, nunca de `string` já decodificada.
- [ ] Conversão de número e data com cultura invariante.
- [ ] `XmlSerializer` em campo `static readonly` (ou cache próprio).
- [ ] Saída **sem BOM**, salvo exigência explícita do parceiro.
- [ ] Validação XSD na entrada, acumulando todos os erros.
- [ ] Arquivo grande processado com `XmlReader`.
- [ ] XML original arquivado como comprovante; campos extraídos em colunas normais.
- [ ] Nenhum dado pessoal do XML em log — veja [`../../dotnet/logging/log-estruturado-e-o-que-nunca-logar.md`](../../dotnet/logging/log-estruturado-e-o-que-nunca-logar.md).

## Referências

- [LINQ to XML](https://learn.microsoft.com/pt-br/dotnet/standard/linq/linq-xml-overview)
- [`XmlReaderSettings`](https://learn.microsoft.com/pt-br/dotnet/api/system.xml.xmlreadersettings)
- [`XmlSerializer`](https://learn.microsoft.com/pt-br/dotnet/api/system.xml.serialization.xmlserializer)
- [Validação por esquema XSD](https://learn.microsoft.com/pt-br/dotnet/standard/data/xml/xml-schema-object-model-soms)
- [Dados XML no SQL Server](https://learn.microsoft.com/pt-br/sql/relational-databases/xml/xml-data-sql-server)

---

**Criado por Fábio Cerqueira**
