/**
 * withAwsAuth - Run a closure inside a Docker image with proper AWS auth.
 *
 * nonprod / nonprod-test:
 *   Uses the Jenkins node's instance profile. The container runs with
 *   --network host so it can reach the EC2 metadata service (IMDS).
 *
 * prod:
 *   Assumes the 'jenkins' role in the prod AWS account via STS, then
 *   passes the temporary credentials into the container.
 *
 * Usage:
 *   withAwsAuth('nonprod-test', img) {
 *       sh './scripts/cluster-status.sh'
 *   }
 *
 *   withAwsAuth('prod', img, '-e VAULT_SKIP_VERIFY=true') {
 *       sh 'vault status'
 *   }
 */

// Cross-account role for prod. Jenkins nodes run in nonprod and assume
// this role to operate in the prod AWS account.
PROD_ROLE_ARN = 'arn:aws:iam::<PROD_ACCOUNT_ID>:role/jenkins'

// Region per environment (all us-east-1 today but kept explicit)
ENV_REGIONS = [
    'nonprod-test': 'us-east-1',
    'nonprod':      'us-east-1',
    'prod':         'us-east-1',
]

def call(String envName, img, String extraArgs = '', Closure body) {
    def region = ENV_REGIONS[envName] ?: 'us-east-1'

    if (envName == 'prod') {
        // Assume role from the Jenkins node (which has IMDS access)
        def creds = sh(
            script: """
                CREDS=\$(aws sts assume-role \
                    --role-arn '${PROD_ROLE_ARN}' \
                    --role-session-name "jenkins-vault-\${BUILD_NUMBER}" \
                    --output json)
                echo "\$CREDS" | jq -r '[.Credentials.AccessKeyId, .Credentials.SecretAccessKey, .Credentials.SessionToken] | join("|")'
            """,
            returnStdout: true
        ).trim().split('\\|')

        withEnv([
            "AWS_ACCESS_KEY_ID=${creds[0]}",
            "AWS_SECRET_ACCESS_KEY=${creds[1]}",
            "AWS_SESSION_TOKEN=${creds[2]}",
            "AWS_DEFAULT_REGION=${region}"
        ]) {
            img.inside("-e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN -e AWS_DEFAULT_REGION ${extraArgs}".trim()) {
                body()
            }
        }
    } else {
        // nonprod: instance profile via host network for IMDS access
        img.inside("--network host -e AWS_DEFAULT_REGION=${region} ${extraArgs}".trim()) {
            body()
        }
    }
}
