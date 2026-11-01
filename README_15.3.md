# Домашнее задание к занятию "`Безопасность в облачных провайдерах`" - `Шмагин Максим`

### Задание 1. Yandex Cloud

## В качестве решения добавил код ниже в main.tf

# Даем сервисному аккаунту права на шифрование/расшифрование
resource "yandex_resourcemanager_folder_iam_member" "kms_encrypter_decrypter" {
  folder_id = var.folder_id
  role      = "kms.keys.encrypterDecrypter"
  member    = "serviceAccount:${yandex_iam_service_account.ig_sa.id}"
}

# Создаем симметричный ключ KMS
resource "yandex_kms_symmetric_key" "bucket_key" {
  name              = "bucket-key"
  description       = "Ключ для шифрования бакета"
  default_algorithm = "AES_128"
  rotation_period   = "8760h" # Период ротации 1 год
}

resource "yandex_storage_bucket" "netology_bucket" {
  access_key = yandex_iam_service_account_static_access_key.sa_static_key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa_static_key.secret_key
  bucket     = "netology-student-${random_string.bucket_name.result}"
  
  anonymous_access_flags {
    read = true
    list = false
  }

  # Добавляем блок шифрования
  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        kms_master_key_id = yandex_kms_symmetric_key.bucket_key.id
        sse_algorithm     = "aws:kms"
      }
    }
  }

  # Ждем выдачи прав на KMS
  depends_on = [
    yandex_resourcemanager_folder_iam_member.kms_encrypter_decrypter
  ]
}