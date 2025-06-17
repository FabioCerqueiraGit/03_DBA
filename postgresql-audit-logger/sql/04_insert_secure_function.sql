-- Etapa 4: Exemplo de criptografia (armazenar CPF de forma segura)
ALTER TABLE public.usuarios ALTER COLUMN cpf TYPE BYTEA;

-- Criação de função de inserção segura com criptografia
CREATE OR REPLACE FUNCTION public.inserir_usuario_seguro(
    p_nome TEXT,
    p_email TEXT,
    p_cpf TEXT
) RETURNS VOID AS $$
BEGIN
    INSERT INTO public.usuarios(nome, email, cpf)
    VALUES (
        p_nome,
        p_email,
        pgp_sym_encrypt(p_cpf, 'chave-secreta')
    );
END;
$$ LANGUAGE plpgsql;