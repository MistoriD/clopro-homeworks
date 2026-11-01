### cloud vars
variable "cloud_id" {
  type = string
}
variable "folder_id" {
  type = string
}

### network var
variable "default_zone" {
  type    = string
  default = "ru-central1-a"
}

### ssh vars
variable "ssh_key" {
  type = string
}

### compute vars
variable "vm_resources" {
  type = map(object({
    cores         = number
    memory        = number
    core_fraction = number
    preemptible   = bool
    disk_type     = string
    disk_size     = number
  }))
  default = {
    vm = {
      cores         = 2
      memory        = 2
      core_fraction = 100
      preemptible   = false
      disk_type     = "network-hdd"
      disk_size     = 20
    }
  }
}

variable "vm_image_id" {
  type    = string
  default = "ubuntu-2204-lts"
}