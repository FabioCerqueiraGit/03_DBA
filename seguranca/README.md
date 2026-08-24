# Segurança

> As quatro perguntas que qualquer sistema C#/.NET com SQL Server precisa responder — e onde está
> a resposta neste repositório.

---

## Conteúdo

| Pergunta | Documento |
|---|---|
| "Esse sistema é injetável? Como eu descubro?" | [SQL Injection — prevenir na aplicação, encontrar no banco](sql-injection/prevenir-e-encontrar-sql-injection.md) |
| "Onde a senha do banco deveria estar?" | [Gerenciamento de segredos em aplicações .NET](secrets/gerenciamento-de-segredos-em-aplicacoes-dotnet.md) |
| "A integração começou a dar erro de certificado. E agora?" | [TLS e certificados em .NET](certificados/tls-e-certificados-em-dotnet.md) |
| "As senhas dos usuários estão em MD5. Como sair disso?" | [Armazenamento seguro de senhas](senhas/armazenamento-seguro-de-senhas.md) |

Assuntos correlatos em outras áreas:

- **Autenticação em APIs** (Basic, Bearer, JWT, OAuth): [`api-integracao/autenticacao/`](../api-integracao/autenticacao/)
- **Permissões e menor privilégio no SQL Server**: [`sql-server/administracao/`](../sql-server/administracao/)
- **Segredo vazado no histórico do Git**: [`devops/git/remover-segredo-vazado-do-historico.md`](../devops/git/remover-segredo-vazado-do-historico.md)
- **O que nunca escrever em log** (incluindo dado pessoal): [`dotnet/logging/`](../dotnet/logging/)

---

## Os quatro atalhos que sempre reaparecem

Cada um deles "resolve" um erro em minutos e cria um problema que dura anos. Se você encontrar
qualquer um destes em um sistema, ele merece um item no backlog:

**1. `ServerCertificateValidationCallback = (s, c, ch, e) => true`**
Desliga a autenticação do TLS. A conexão continua criptografada, mas você deixou de saber com
quem está falando. O caminho certo está em
[certificados/](certificados/tls-e-certificados-em-dotnet.md).

**2. `TrustServerCertificate=True` na connection string**
A mesma coisa, entre a aplicação e o SQL Server. Muito comum após migrar para
`Microsoft.Data.SqlClient` 4.0+, que passou a exigir criptografia por padrão.

**3. `db_owner` para o usuário da aplicação**
Quase sempre nasce de um erro de permissão resolvido com pressa. Transforma qualquer injeção
bem-sucedida em comprometimento total do banco.

**4. Sanitizar entrada em vez de parametrizar**
Remover apóstrofo e a palavra `DROP` é uma corrida que o atacante vence. Parâmetro não é uma
limpeza melhor — é um mecanismo diferente, em que o dado nunca chega a ser interpretado como
código.

---

## Regra do repositório

Nenhum documento deste projeto contém senha real, connection string real, token, API key,
certificado privado, nome de servidor ou nome de cliente. Todos os exemplos usam placeholders
explícitos:

```text
Server=<SERVIDOR>;Database=<BANCO>;User Id=<USUARIO>;Password=<SENHA>;
https://<HOST-DA-API>/v1/pedidos
```

Se você contribuir com este repositório, essa regra vale para o seu Pull Request também — ver
[CONTRIBUTING.md](../CONTRIBUTING.md).

---

## Ordem de prioridade em um sistema legado

Quando se herda um sistema antigo e há tempo limitado, esta é a ordem que costuma render mais:

1. **Inventariar SQL dinâmico.** O script de auditoria em
   [sql-injection/](sql-injection/prevenir-e-encontrar-sql-injection.md) produz a lista em segundos.
   Priorize as procedures com `EXECUTE AS`.
2. **Verificar o privilégio do usuário da aplicação.** Reduzir de `db_owner` para permissão de
   schema costuma ser barato e muda o desfecho de qualquer incidente.
3. **Procurar segredo no repositório.** `git log -p --all -S "Password="`. Se encontrar,
   o passo um é rotacionar, não limpar o histórico.
4. **Verificar como as senhas de usuário estão armazenadas.** Se for MD5 ou SHA-1, a migração
   oportunista em [senhas/](senhas/armazenamento-seguro-de-senhas.md) resolve sem incomodar
   ninguém.
5. **Verificar vencimento dos certificados.** Barato de monitorar, caro de descobrir por incidente.

Nada disso exige reescrever o sistema — e essa é exatamente a intenção.

---

**Criado por Fábio Cerqueira**
