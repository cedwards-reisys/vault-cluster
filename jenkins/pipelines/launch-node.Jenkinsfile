// Vault Cluster - Launch Node (scripted pipeline)

def envName = env.JOB_NAME.split('/')[1]

properties([
    parameters([
        choice(name: 'AZ_INDEX', choices: ['0', '1', '2'], description: 'Availability zone index')
    ])
])

node {
    timestamps {
        ansiColor('xterm') {
            try {
                stage('Checkout') {
                    checkout scm
                }

                def img = buildVaultOpsImage()

                stage('Launch Node') {
                    withAwsAuth(envName, img) {
                        sh "./scripts/launch-node.sh ${envName} ${params.AZ_INDEX} --yes"
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
