// Vault Cluster - Terminate Node (scripted pipeline)
// Vault token fetched from AWS Secrets Manager at runtime.

def envName = env.JOB_NAME.split('/')[1]
def clusterName = "vault-${envName}"

properties([
    parameters([
        string(name: 'INSTANCE_ID', defaultValue: '', description: 'EC2 instance ID to terminate (e.g., i-0abc123)'),
        booleanParam(name: 'REMOVE_FROM_RAFT', defaultValue: false, description: 'Permanently remove from Raft cluster')
    ])
])

node {
    timestamps {
        ansiColor('xterm') {
            try {
                if (!params.INSTANCE_ID?.trim()) {
                    error('INSTANCE_ID is required')
                }

                stage('Checkout') {
                    checkout scm
                }

                def img = buildVaultOpsImage()

                stage('Approve') {
                    input message: "Terminate instance ${params.INSTANCE_ID} in ${envName}?", ok: 'Terminate'
                }

                stage('Terminate Node') {
                    withAwsAuth(envName, img) {
                        def raftFlag = params.REMOVE_FROM_RAFT ? '--remove-from-raft' : ''
                        sh """
                            export VAULT_TOKEN=\$(aws secretsmanager get-secret-value \
                                --secret-id ${clusterName}/vault/root-token \
                                --query SecretString --output text | jq -r '.token')

                            ./scripts/terminate-node.sh ${envName} ${params.INSTANCE_ID} ${raftFlag} --yes
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
