# 1. Сеть и подсеть
resource "yandex_vpc_network" "my_network" {
  name = "netology-network"
}

resource "yandex_vpc_subnet" "public_subnet" {
  name           = "public"
  v4_cidr_blocks = ["192.168.10.0/24"]
  zone           = var.default_zone
  network_id     = yandex_vpc_network.my_network.id
}

# 2. Сервисный аккаунт для Instance Group и Object Storage
resource "yandex_iam_service_account" "ig_sa" {
  name        = "ig-sa"
  description = "Сервисный аккаунт для управления группой ВМ и бакетом"
}

resource "yandex_resourcemanager_folder_iam_member" "editor" {
  folder_id = var.folder_id
  role      = "editor"
  member    = "serviceAccount:${yandex_iam_service_account.ig_sa.id}"
}

# Пауза в 15 секунд, чтобы права успели примениться на серверах Yandex Cloud
resource "time_sleep" "wait_for_iam" {
  create_duration = "15s"
  depends_on      = [yandex_resourcemanager_folder_iam_member.editor]
}


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

# Статические ключи для доступа к Object Storage
resource "yandex_iam_service_account_static_access_key" "sa_static_key" {
  service_account_id = yandex_iam_service_account.ig_sa.id
  description        = "Статический ключ для бакета"
}

# 3. Object Storage (Бакет и объект)
# Генерируем уникальную строку для имени бакета
resource "random_string" "bucket_name" {
  length  = 8
  special = false
  upper   = false
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

resource "yandex_storage_object" "picture" {
  access_key = yandex_iam_service_account_static_access_key.sa_static_key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa_static_key.secret_key
  bucket     = yandex_storage_bucket.netology_bucket.bucket
  key        = "picture.jpg"
  source     = "picture.jpg" 
  # Строку acl мы убрали, так как весь бакет уже доступен на чтение
  depends_on = [yandex_storage_bucket.netology_bucket]
}

# 4. Instance Group (Группа ВМ)
resource "yandex_compute_instance_group" "lamp_group" {
  name               = "lamp-group"
  folder_id          = var.folder_id
  service_account_id = yandex_iam_service_account.ig_sa.id
  depends_on         = [yandex_resourcemanager_folder_iam_member.editor]
  
  instance_template {
    platform_id = "standard-v3"
    resources {
      memory        = 2
      cores         = 2
      core_fraction = 20 # Снижаем CPU для экономии квот
    }
    boot_disk {
      mode = "READ_WRITE"
      initialize_params {
        image_id = "fd827b91d99psvq5fjit" # LAMP образ из задания
        size     = 10
      }
    }
    network_interface {
      network_id = yandex_vpc_network.my_network.id
      subnet_ids = [yandex_vpc_subnet.public_subnet.id]
      nat        = true
    }
    metadata = {
      ssh-keys = "ubuntu:${var.ssh_key}"
      # bash-скрипт, который создаст стартовую страницу с картинкой при запуске ВМ
      user-data = <<EOF
#!/bin/bash
echo "<html><head><title>Netology LB Test</title></head><body><h1>Hello from Yandex Cloud!</h1><img src='https://${yandex_storage_bucket.netology_bucket.bucket}.storage.yandexcloud.net/${yandex_storage_object.picture.key}'/></body></html>" > /var/www/html/index.html
EOF
    }
  }

  scale_policy {
    fixed_scale {
      size = 3 # 3 ВМ по заданию
    }
  }

  allocation_policy {
    zones = [var.default_zone]
  }

  deploy_policy {
    max_unavailable = 1
    max_creating    = 3
    max_expansion   = 1
    max_deleting    = 1
  }

  health_check {
    interval = 15
    timeout  = 5
    unhealthy_threshold = 2
    healthy_threshold   = 2
    http_options {
      port = 80
      path = "/"
    }
  }

  # Указываем, что группу нужно связать с балансировщиком
  load_balancer {
    target_group_name = "lamp-tg"
  }
}

# 5. Network Load Balancer (Сетевой балансировщик)
resource "yandex_lb_network_load_balancer" "lb" {
  name = "lamp-lb"

  listener {
    name = "http-listener"
    port = 80
    external_address_spec {
      ip_version = "ipv4"
    }
  }

  attached_target_group {
    target_group_id = yandex_compute_instance_group.lamp_group.load_balancer[0].target_group_id
    
    healthcheck {
      name = "http"
      http_options {
        port = 80
        path = "/"
      }
    }
  }
}

# Вывод IP-адреса балансировщика в консоль после успешного создания
output "load_balancer_ip" {
  value = yandex_lb_network_load_balancer.lb.listener.*.external_address_spec[0].*.address
}