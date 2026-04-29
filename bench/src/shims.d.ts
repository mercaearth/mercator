declare const process: {
  env: Record<string, string | undefined>;
  exit(code?: number): never;
};

declare module "fs" {
  export function appendFileSync(...args: any[]): any;
  export function existsSync(...args: any[]): any;
  export function mkdirSync(...args: any[]): any;
  export function writeFileSync(...args: any[]): any;
}

declare module "child_process" {
  export function execSync(...args: any[]): any;
}

declare module "path" {
  export function dirname(...args: any[]): any;
  export function join(...args: any[]): any;
}

declare module "url" {
  export function fileURLToPath(...args: any[]): any;
}

declare module "dotenv" {
  export function config(...args: any[]): any;
}

declare module "@mysten/sui/client" {
  export class SuiClient {
    constructor(args: any);
    signAndExecuteTransaction(args: any): Promise<any>;
    getTransactionBlock(args: any): Promise<any>;
  }
}

declare module "@mysten/sui/keypairs/ed25519" {
  export class Ed25519Keypair {
    static fromSecretKey(key: string): Ed25519Keypair;
    toSuiAddress(): string;
  }
}

declare module "@mysten/sui/transactions" {
  export class Transaction {
    pure: {
      vector(type: string, value: any): any;
    };
    setGasBudget(value: number): void;
    setSender(value: string): void;
    object(id: string): any;
    moveCall(args: any): any;
    transferObjects(objects: any[], address: string): void;
  }
}
