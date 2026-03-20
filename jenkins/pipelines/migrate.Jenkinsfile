// Vault Cluster - Migration Pipeline (scripted pipeline)
// Legacy Vault token passed as a build parameter (legacy cluster has no Secrets Manager secret).
// New cluster credentials are stored into Secrets Manager after initialization.

def envName = env.JOB_NAME.split('/')[-1].replace('migrate-', '')
def clusterName = "vault-${envName}"

properties([
    parameters([
        string(name: 'LEGACY_VAULT_ADDR', defaultValue: '', description: 'Address of the legacy Vault cluster'),
        password(name: 'LEGACY_VAULT_TOKEN', defaultValue: '', description: 'Root token for legacy cluster'),
        booleanParam(name: 'SKIP_INFRA_DEPLOY', defaultValue: false, description: 'Skip tofu apply (infra already deployed)')
    ])
])

node {
    timestamps {
        ansiColor('xterm') {
            try {
                if (!params.LEGACY_VAULT_ADDR?.trim()) {
                    error('LEGACY_VAULT_ADDR is required')
                }
                if (!params.LEGACY_VAULT_TOKEN?.trim()) {
                    error('LEGACY_VAULT_TOKEN is required')
                }

                stage('Checkout') {
                    checkout scm
                }

                def img = buildVaultOpsImage()

                stage('Snapshot Legacy Cluster') {
                    img.inside("-e VAULT_SKIP_VERIFY=true") {
                        sh """
                            export VAULT_ADDR='${params.LEGACY_VAULT_ADDR}'
                            export VAULT_TOKEN='${params.LEGACY_VAULT_TOKEN}'
                            export VAULT_SKIP_VERIFY=true

                            vault status
                            vault operator raft snapshot save migration-${envName}-\$(date +%Y%m%d-%H%M%S).snap
                            ls -lh migration-${envName}-*.snap
                        """
                    }
                }

                if (!params.SKIP_INFRA_DEPLOY) {
                    stage('Deploy Infrastructure') {
                        withAwsAuth(envName, img) {
                            sh "./scripts/env.sh ${envName} apply -auto-approve"
                        }
                    }
                }

                stage('Approve Migration') {
                    input message: """Ready to migrate ${envName}.
This will:
  1. Launch a new Vault node
  2. Initialize the new cluster (new recovery keys)
  3. Restore the legacy snapshot
  4. Launch remaining nodes
  5. Store new credentials in Secrets Manager
Continue?""", ok: 'Migrate'
                }

                stage('Launch First Node') {
                    withAwsAuth(envName, img) {
                        sh "./scripts/launch-node.sh ${envName} 0 --yes"
                    }
                }

                stage('Initialize + Restore + Store Credentials') {
                    def nlbDns = ''
                    withAwsAuth(envName, img) {
                        nlbDns = sh(
                            script: "aws ssm get-parameter --name /${clusterName}/config/vault-config --query Parameter.Value --output text | jq -r .nlb_dns_name",
                            returnStdout: true
                        ).trim()
                    }

                    def newVaultAddr = "https://${nlbDns}"

                    withAwsAuth(envName, img, '-e VAULT_SKIP_VERIFY=true') {
                        sh """
                            export VAULT_ADDR="${newVaultAddr}"
                            export VAULT_SKIP_VERIFY=true

                            echo "Waiting for Vault to be reachable..."
                            for i in \$(seq 1 30); do
                                if curl -sk "\$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; then
                                    break
                                fi
                                echo "Attempt \$i/30..."
                                sleep 10
                            done

                            echo ""
                            echo "=== Initializing Vault ==="
                            INIT_OUTPUT=\$(vault operator init -recovery-shares=5 -recovery-threshold=3 -format=json)

                            ROOT_TOKEN=\$(echo "\$INIT_OUTPUT" | jq -r '.root_token')
                            export VAULT_TOKEN="\$ROOT_TOKEN"

                            echo ""
                            echo "=== Restoring snapshot ==="
                            SNAP_FILE=\$(ls -t migration-${envName}-*.snap | head -1)
                            vault operator raft snapshot restore -force "\$SNAP_FILE"

                            sleep 5
                            vault status

                            echo ""
                            echo "=== Storing credentials in Secrets Manager ==="

                            # Store root token
                            echo "\$INIT_OUTPUT" | jq '{token: .root_token}' > /tmp/root-token.json
                            aws secretsmanager put-secret-value \
                                --secret-id ${clusterName}/vault/root-token \
                                --secret-string file:///tmp/root-token.json
                            echo "Root token stored."

                            # Store recovery keys
                            echo "\$INIT_OUTPUT" | jq '{keys: .recovery_keys, keys_base64: .recovery_keys_base64}' > /tmp/recovery-keys.json
                            aws secretsmanager put-secret-value \
                                --secret-id ${clusterName}/vault/recovery-keys \
                                --secret-string file:///tmp/recovery-keys.json
                            echo "Recovery keys stored."

                            rm -f /tmp/root-token.json /tmp/recovery-keys.json
                            echo ""
                            echo "Credentials saved to Secrets Manager. No manual step needed."
                        """
                    }
                }

                stage('Launch Remaining Nodes') {
                    withAwsAuth(envName, img) {
                        sh """
                            ./scripts/launch-node.sh ${envName} 1 --yes
                            sleep 30
                            ./scripts/launch-node.sh ${envName} 2 --yes
                        """
                    }
                }

                stage('Verify') {
                    withAwsAuth(envName, img) {
                        sh """
                            export VAULT_TOKEN=\$(aws secretsmanager get-secret-value \
                                --secret-id ${clusterName}/vault/root-token \
                                --query SecretString --output text | jq -r '.token')

                            ./scripts/cluster-status.sh ${envName} || true
                        """
                    }
                }

                archiveArtifacts artifacts: 'migration-*.snap', allowEmptyArchive: true

                echo """
Migration complete for ${envName}!

Credentials have been automatically stored in Secrets Manager.
Next steps:
  1. Update DNS to point to new NLB
  2. Verify application connectivity
  3. Set up backup auth: Run the setup-backup-auth job
  4. Keep old cluster running for 24-48h as fallback
"""
            } catch (e) {
                echo "Migration failed. The legacy cluster is still running and unaffected."
                throw e
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
