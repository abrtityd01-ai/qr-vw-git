import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as rds from 'aws-cdk-lib/aws-rds';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import { Construct } from 'constructs';

export class AuroraServerlessStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // 1. VPC con Restricción de AZs (Evitamos us-east-1e por limitaciones de v2)
    // CORRECCIÓN: Eliminamos 'maxAzs' ya que usamos 'availabilityZones' explícitamente
    const vpc = new ec2.Vpc(this, 'QRVpc', {
      availabilityZones: ['us-east-1a', 'us-east-1b'], // Zonas con alta disponibilidad de v2
      subnetConfiguration: [
        {
          name: 'Isolated',
          subnetType: ec2.SubnetType.PRIVATE_ISOLATED,
        },
      ],
    });

    // 2. Conectividad Privada (PrivateLink)
    vpc.addInterfaceEndpoint('SecretsManagerEndpoint', {
      service: ec2.InterfaceVpcEndpointAwsService.SECRETS_MANAGER,
    });

    vpc.addInterfaceEndpoint('RdsDataApiEndpoint', {
      service: ec2.InterfaceVpcEndpointAwsService.RDS_DATA,
    });

    // 3. Cluster de Aurora Serverless v2
    const cluster = new rds.DatabaseCluster(this, 'QRDatabase', {
      engine: rds.DatabaseClusterEngine.auroraMysql({ 
        version: rds.AuroraMysqlEngineVersion.VER_3_05_2 
      }),
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_ISOLATED },
      writer: rds.ClusterInstance.serverlessV2('writer', {
        publiclyAccessible: false,
      }),
      serverlessV2MinCapacity: 0.5,
      serverlessV2MaxCapacity: 1.0,
      enableDataApi: true, 
      storageEncrypted: true,
      defaultDatabaseName: 'qrdb',
      credentials: rds.Credentials.fromGeneratedSecret('admin'),
      removalPolicy: cdk.RemovalPolicy.DESTROY, 
    });

    // 4. Lambda Procesadora
    const qrProcessor = new lambda.Function(this, 'QRProcessor', {
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'index.handler',
      code: lambda.Code.fromInline(`
        exports.handler = async (event) => {
          console.log("Iniciando procesamiento...");
          return { statusCode: 200, body: JSON.stringify({ message: "Data API Ready" }) };
        };
      `),
      environment: {
        DB_CLUSTER_ARN: cluster.clusterArn,
        SECRET_ARN: cluster.secret?.secretArn || '',
      },
      tracing: lambda.Tracing.ACTIVE,
    });

    // 5. Permisos de IAM
    cluster.grantDataApiAccess(qrProcessor);
    if (cluster.secret) {
      cluster.secret.grantRead(qrProcessor);
    }

    // 6. Outputs
    new cdk.CfnOutput(this, 'ClusterArn', { value: cluster.clusterArn });
    new cdk.CfnOutput(this, 'SecretArn', { value: cluster.secret?.secretArn || '' });
  }
}
