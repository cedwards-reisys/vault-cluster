// Vault Cluster - Setup Audit Device (scripted pipeline)
//
// One-time per cluster (idempotent). Enables the file audit device at
// /var/log/vault/audit.log — Splunk forwarder picks it up via its existing
// /var/log scan. Logrotate config is pre-baked in userdata.
//
// IMPORTANT: once enabled, Vault blocks all requests if the audit destination
// is unwritable. Directory + logrotate config are pre-created in userdata to
// reduce the chance of a first-enable failure.

def envName = env.JOB_NAME.split('/')[1]
def clusterName = "vault-${envName}"

node {
    timestamps {
        ansiColor('xterm') {
            try {
                stage('Checkout') {
                    checkout scm
                }

                def img = buildVaultOpsImage()

                def vaultAddr = ''
                withAwsAuth(envName, img) {
                    vaultAddr = sh(
                        script: "aws ssm get-parameter --name /${clusterName}/config/vault-url --query Parameter.Value --output text",
                        returnStdout: true
                    ).trim()
                }
                echo "Vault Address: ${vaultAddr}"

                stage('Approve') {
                    input message: "Enable audit device on ${envName}? Vault will block requests if /var/log/vault/audit.log becomes unwritable.", ok: 'Proceed'
                }

                stage('Enable') {
                    withAwsAuth(envName, img) {
                        sh """
                            export VAULT_TOKEN=\$(aws secretsmanager get-secret-value \
                                --secret-id ${clusterName}/vault/root-token \
                                --query SecretString --output text | jq -r '.token')
                            export VAULT_ADDR=${vaultAddr}

                            # Check if audit device is already enabled (idempotent)
                            if vault audit list -format=json 2>/dev/null | jq -e '."file/"' >/dev/null 2>&1; then
                                echo "Audit device 'file/' already enabled — no changes made."
                            else
                                vault audit enable file \\
                                    file_path=/var/log/vault/audit.log \\
                                    log_raw=false
                                echo "Audit device enabled at /var/log/vault/audit.log"
                                echo "Requests are now being logged to Splunk via /var/log scan."
                            fi

                            echo ""
                            echo "Current audit devices:"
                            vault audit list
                        """
                    }
                }
            } finally {
                cleanWs()
            }
        }
    }
}

def buildVaultOpsImage() {
    stage('Build Docker Image') {
        return docker.build("vault-ops:${env.BUILD_TAG}", ".")
    }
}
