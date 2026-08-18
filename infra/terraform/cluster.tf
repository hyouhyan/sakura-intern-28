########################################
# クラスタ
########################################
resource "sakura_apprun_dedicated_cluster" "example" {
  name                 = var.cluster_name
  service_principal_id = var.service_principal_id
  lets_encrypt_email   = var.cluster_lets_encrypt_email
  ports = [
    {
      port     = 80
      protocol = "http"
    },
    {
      port     = 443
      protocol = "https"
    }
  ]
}
